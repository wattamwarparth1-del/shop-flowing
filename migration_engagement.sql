-- ═══════════════════════════════════════════════════════════════
-- ShopFlow Migration — Customer Engagement & Messaging
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.customer_messages (
    id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    shop_id         UUID REFERENCES public.shops(id) ON DELETE CASCADE NOT NULL,
    customer_id     UUID REFERENCES public.customers(id) ON DELETE CASCADE NOT NULL,
    sent_by         TEXT, -- Staff ID or Name
    message         TEXT NOT NULL,
    channel         TEXT DEFAULT 'SMS',
    status          TEXT DEFAULT 'Pending',
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    delivered_at    TIMESTAMPTZ,
    failed_at       TIMESTAMPTZ
);

-- Enable RLS
ALTER TABLE public.customer_messages ENABLE ROW LEVEL SECURITY;

-- Allow all authenticated/anon to read and insert (since staff login uses anon)
-- For proper security, we depend on the app passing the correct shop_id.
CREATE POLICY "Enable read for shop" ON public.customer_messages
    FOR SELECT USING (true);

CREATE POLICY "Enable insert for shop" ON public.customer_messages
    FOR INSERT WITH CHECK (true);

-- RPC to get engagement customer list efficiently
CREATE OR REPLACE FUNCTION public.get_engagement_customers(p_shop_id UUID)
RETURNS JSON AS $$
DECLARE
    v_result JSON;
BEGIN
    SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) INTO v_result
    FROM (
        SELECT 
            c.id, c.name, c.mobile, c.created_at as customer_since,
            c.total_bills, c.total_spent,
            (SELECT MAX(created_at) FROM public.bills WHERE customer_id = c.id AND shop_id = p_shop_id AND status ILIKE 'completed') as last_purchase_date
        FROM public.customers c
        WHERE c.shop_id = p_shop_id
        ORDER BY last_purchase_date DESC NULLS LAST
    ) t;
    
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.get_engagement_customers TO anon, authenticated;

-- RPC to get customer insights
CREATE OR REPLACE FUNCTION public.get_customer_insights(p_shop_id UUID, p_customer_id UUID)
RETURNS JSON AS $$
DECLARE
    v_result JSON;
BEGIN
    SELECT row_to_json(t) INTO v_result
    FROM (
        SELECT 
            (SELECT MAX(created_at) FROM public.bills WHERE customer_id = p_customer_id AND status ILIKE 'completed') as last_purchase_date,
            (SELECT COUNT(*) FROM public.bills WHERE customer_id = p_customer_id AND status ILIKE 'completed') as total_purchases,
            (SELECT COALESCE(SUM(grand_total), 0) FROM public.bills WHERE customer_id = p_customer_id AND status ILIKE 'completed') as total_spent,
            (
                SELECT p.category 
                FROM public.bill_items bi
                JOIN public.bills b ON bi.bill_id = b.id
                JOIN public.products p ON bi.product_id = p.id
                WHERE b.customer_id = p_customer_id AND b.status ILIKE 'completed'
                GROUP BY p.category
                ORDER BY COUNT(*) DESC
                LIMIT 1
            ) as favorite_category
    ) t;
    
    RETURN COALESCE(v_result, '{}'::json);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.get_customer_insights TO anon, authenticated;
