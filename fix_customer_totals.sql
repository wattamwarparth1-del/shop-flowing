CREATE OR REPLACE FUNCTION public.get_engagement_customers(p_shop_id UUID)
RETURNS JSON AS $$
DECLARE
    v_result JSON;
BEGIN
    SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) INTO v_result
    FROM (
        SELECT 
            c.id, c.name, c.mobile, c.created_at as customer_since,
            (SELECT COUNT(*) FROM public.bills WHERE customer_id = c.id AND shop_id = p_shop_id AND status ILIKE 'completed') as total_bills,
            (SELECT COALESCE(SUM(grand_total), 0) FROM public.bills WHERE customer_id = c.id AND shop_id = p_shop_id AND status ILIKE 'completed') as total_spent,
            (SELECT MAX(created_at) FROM public.bills WHERE customer_id = c.id AND shop_id = p_shop_id AND status ILIKE 'completed') as last_purchase_date
        FROM public.customers c
        WHERE c.shop_id = p_shop_id
        ORDER BY last_purchase_date DESC NULLS LAST
    ) t;
    
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
