-- ═══════════════════════════════════════════════════════════════
-- ShopFlow Phase 4 — Reports & Analytics Stored Functions
-- Run this entire file in: Supabase Dashboard → SQL Editor → Run
-- ═══════════════════════════════════════════════════════════════

-- 1. Product Sales Summary Report
CREATE OR REPLACE FUNCTION public.get_product_sales_report(
  p_shop_id    UUID,
  p_start_date TIMESTAMPTZ DEFAULT '1970-01-01',
  p_end_date   TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE (
  product_id      UUID,
  product_name    TEXT,
  category        TEXT,
  total_qty_sold  NUMERIC,
  total_revenue   NUMERIC
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    bi.product_id,
    bi.product_name,
    COALESCE(p.category, 'General') AS category,
    SUM(bi.quantity) AS total_qty_sold,
    SUM(bi.total_amount) AS total_revenue
  FROM public.bill_items bi
  JOIN public.bills b ON b.id = bi.bill_id
  LEFT JOIN public.products p ON p.id = bi.product_id
  WHERE bi.shop_id = p_shop_id
    AND b.created_at >= p_start_date
    AND b.created_at <= p_end_date
  GROUP BY bi.product_id, bi.product_name, p.category
  ORDER BY total_revenue DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2. Staff Performance Report
CREATE OR REPLACE FUNCTION public.get_staff_sales_report(
  p_shop_id    UUID,
  p_start_date TIMESTAMPTZ DEFAULT '1970-01-01',
  p_end_date   TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE (
  staff_id        TEXT,
  staff_name      TEXT,
  total_bills     BIGINT,
  total_revenue   NUMERIC
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    COALESCE(b.staff_id, 'Unassigned') AS staff_id,
    COALESCE(b.staff_name, 'Unknown Staff') AS staff_name,
    COUNT(b.id) AS total_bills,
    SUM(b.grand_total) AS total_revenue
  FROM public.bills b
  WHERE b.shop_id = p_shop_id
    AND b.created_at >= p_start_date
    AND b.created_at <= p_end_date
  GROUP BY b.staff_id, b.staff_name
  ORDER BY total_revenue DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3. POS Machine Sales Report
CREATE OR REPLACE FUNCTION public.get_pos_sales_report(
  p_shop_id    UUID,
  p_start_date TIMESTAMPTZ DEFAULT '1970-01-01',
  p_end_date   TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE (
  pos_id          TEXT,
  total_bills     BIGINT,
  total_revenue   NUMERIC
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    COALESCE(b.pos_id, 'Main POS') AS pos_id,
    COUNT(b.id) AS total_bills,
    SUM(b.grand_total) AS total_revenue
  FROM public.bills b
  WHERE b.shop_id = p_shop_id
    AND b.created_at >= p_start_date
    AND b.created_at <= p_end_date
  GROUP BY b.pos_id
  ORDER BY total_revenue DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 4. Payment Methods Summary Report
CREATE OR REPLACE FUNCTION public.get_payment_summary_report(
  p_shop_id    UUID,
  p_start_date TIMESTAMPTZ DEFAULT '1970-01-01',
  p_end_date   TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE (
  payment_method  TEXT,
  total_bills     BIGINT,
  total_revenue   NUMERIC
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    b.payment_method,
    COUNT(b.id) AS total_bills,
    SUM(b.grand_total) AS total_revenue
  FROM public.bills b
  WHERE b.shop_id = p_shop_id
    AND b.created_at >= p_start_date
    AND b.created_at <= p_end_date
  GROUP BY b.payment_method
  ORDER BY total_revenue DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 5. Stock Movement Audit Trail Report
CREATE OR REPLACE FUNCTION public.get_stock_movement_report(
  p_shop_id    UUID,
  p_start_date TIMESTAMPTZ DEFAULT '1970-01-01',
  p_end_date   TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE (
  movement_id     UUID,
  product_name    TEXT,
  change_type     TEXT,
  quantity        NUMERIC,
  previous_stock  NUMERIC,
  new_stock       NUMERIC,
  reference_id    TEXT,
  created_by      TEXT,
  created_at      TIMESTAMPTZ
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    sm.id AS movement_id,
    p.name AS product_name,
    sm.change_type,
    sm.quantity,
    sm.previous_stock,
    sm.new_stock,
    sm.reference_id,
    sm.created_by,
    sm.created_at
  FROM public.stock_movements sm
  JOIN public.products p ON p.id = sm.product_id
  WHERE sm.shop_id = p_shop_id
    AND sm.created_at >= p_start_date
    AND sm.created_at <= p_end_date
  ORDER BY sm.created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.get_product_sales_report TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_staff_sales_report TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_pos_sales_report TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_payment_summary_report TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_stock_movement_report TO anon, authenticated;
