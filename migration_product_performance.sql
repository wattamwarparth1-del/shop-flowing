-- ═══════════════════════════════════════════════════════════════
-- ShopFlow Migration — Product Performance RPC
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.get_product_performance(
    p_shop_id UUID,
    p_start_date TIMESTAMPTZ,
    p_end_date TIMESTAMPTZ
) RETURNS JSON AS $$
DECLARE
    v_top_products JSON;
    v_top_revenue JSON;
    v_slow_stock JSON;
    v_categories JSON;
BEGIN
    -- Top by quantity
    SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) INTO v_top_products
    FROM (
        SELECT 
            p.id, p.name, p.category, p.stock_quantity,
            SUM(bi.quantity) as qty_sold,
            SUM(bi.total_amount) as revenue
        FROM public.bill_items bi
        JOIN public.bills b ON bi.bill_id = b.id
        JOIN public.products p ON bi.product_id = p.id
        WHERE bi.shop_id = p_shop_id 
          AND b.created_at >= p_start_date 
          AND b.created_at <= p_end_date
          AND b.status ILIKE 'completed'
        GROUP BY p.id, p.name, p.category, p.stock_quantity
        ORDER BY qty_sold DESC
        LIMIT 10
    ) t;

    -- Top by revenue
    SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) INTO v_top_revenue
    FROM (
        SELECT 
            p.id, p.name, p.category, p.stock_quantity,
            SUM(bi.quantity) as qty_sold,
            SUM(bi.total_amount) as revenue
        FROM public.bill_items bi
        JOIN public.bills b ON bi.bill_id = b.id
        JOIN public.products p ON bi.product_id = p.id
        WHERE bi.shop_id = p_shop_id 
          AND b.created_at >= p_start_date 
          AND b.created_at <= p_end_date
          AND b.status ILIKE 'completed'
        GROUP BY p.id, p.name, p.category, p.stock_quantity
        ORDER BY revenue DESC
        LIMIT 10
    ) t;

    -- Categories
    SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) INTO v_categories
    FROM (
        SELECT 
            p.category,
            SUM(bi.quantity) as qty_sold,
            SUM(bi.total_amount) as revenue
        FROM public.bill_items bi
        JOIN public.bills b ON bi.bill_id = b.id
        JOIN public.products p ON bi.product_id = p.id
        WHERE bi.shop_id = p_shop_id 
          AND b.created_at >= p_start_date 
          AND b.created_at <= p_end_date
          AND b.status ILIKE 'completed'
        GROUP BY p.category
        ORDER BY revenue DESC
    ) t;

    -- Slow moving (products in stock but not sold in this date range)
    SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) INTO v_slow_stock
    FROM (
        SELECT 
            p.id, p.name, p.category, p.stock_quantity, p.selling_price
        FROM public.products p
        WHERE p.shop_id = p_shop_id
          AND p.stock_quantity > 0
          AND NOT EXISTS (
              SELECT 1 FROM public.bill_items bi
              JOIN public.bills b ON bi.bill_id = b.id
              WHERE bi.product_id = p.id 
                AND b.created_at >= p_start_date
                AND b.created_at <= p_end_date
                AND b.status ILIKE 'completed'
          )
        ORDER BY p.stock_quantity DESC
        LIMIT 20
    ) t;

    RETURN json_build_object(
        'top_by_qty', v_top_products,
        'top_by_revenue', v_top_revenue,
        'categories', v_categories,
        'slow_stock', v_slow_stock
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.get_product_performance TO anon, authenticated;
