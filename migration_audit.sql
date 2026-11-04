-- ═══════════════════════════════════════════════════════════════
-- ShopFlow Migration — Audit & Activity Center
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.audit_logs (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    shop_id UUID REFERENCES public.shops(id) ON DELETE CASCADE NOT NULL,
    actor_id TEXT,
    actor_name TEXT,
    actor_role TEXT,
    action TEXT NOT NULL,
    category TEXT NOT NULL,
    resource_type TEXT,
    resource_id TEXT,
    resource_name TEXT,
    result TEXT DEFAULT 'SUCCESS',
    reason TEXT,
    before_data JSONB,
    after_data JSONB,
    changed_fields JSONB,
    ip_address TEXT,
    request_id TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Enable RLS
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

-- Allow all authenticated/anon to read and insert (since staff login uses anon)
CREATE POLICY "Enable read for shop audit" ON public.audit_logs
    FOR SELECT USING (true);

CREATE POLICY "Enable insert for shop audit" ON public.audit_logs
    FOR INSERT WITH CHECK (true);

-- NO UPDATE OR DELETE POLICIES = Append-only by default from client side.

-- Index for fast searching
CREATE INDEX idx_audit_shop_id ON public.audit_logs(shop_id);
CREATE INDEX idx_audit_category ON public.audit_logs(category);
CREATE INDEX idx_audit_created_at ON public.audit_logs(created_at DESC);
CREATE INDEX idx_audit_resource ON public.audit_logs(resource_type, resource_id);

-- RPC for fetching audit logs with server-side filtering
CREATE OR REPLACE FUNCTION public.get_audit_logs(
    p_shop_id UUID,
    p_limit INT DEFAULT 100,
    p_offset INT DEFAULT 0,
    p_category TEXT DEFAULT NULL,
    p_action TEXT DEFAULT NULL,
    p_actor TEXT DEFAULT NULL,
    p_search TEXT DEFAULT NULL
) RETURNS JSON AS $$
DECLARE
    v_result JSON;
BEGIN
    SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) INTO v_result
    FROM (
        SELECT *
        FROM public.audit_logs
        WHERE shop_id = p_shop_id
          AND (p_category IS NULL OR p_category = '' OR category = p_category)
          AND (p_action IS NULL OR p_action = '' OR action = p_action)
          AND (p_actor IS NULL OR p_actor = '' OR actor_name ILIKE '%' || p_actor || '%')
          AND (p_search IS NULL OR p_search = '' OR (
              action ILIKE '%' || p_search || '%' OR
              resource_name ILIKE '%' || p_search || '%' OR
              reason ILIKE '%' || p_search || '%'
          ))
        ORDER BY created_at DESC
        LIMIT p_limit OFFSET p_offset
    ) t;
    
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.get_audit_logs TO anon, authenticated;

-- RPC for Audit Overview Stats
CREATE OR REPLACE FUNCTION public.get_audit_stats(p_shop_id UUID)
RETURNS JSON AS $$
DECLARE
    v_result JSON;
BEGIN
    SELECT row_to_json(t) INTO v_result
    FROM (
        SELECT 
            (SELECT COUNT(*) FROM public.audit_logs WHERE shop_id = p_shop_id) as total_events,
            (SELECT COUNT(*) FROM public.audit_logs WHERE shop_id = p_shop_id AND created_at >= CURRENT_DATE) as today_events,
            (SELECT COUNT(*) FROM public.audit_logs WHERE shop_id = p_shop_id AND result = 'FAILED') as failed_actions,
            (SELECT COUNT(*) FROM public.audit_logs WHERE shop_id = p_shop_id AND category = 'Security') as security_events,
            (SELECT COUNT(*) FROM public.audit_logs WHERE shop_id = p_shop_id AND category IN ('Billing', 'Payments', 'Refunds')) as financial_actions
    ) t;
    
    RETURN COALESCE(v_result, '{}'::json);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.get_audit_stats TO anon, authenticated;
