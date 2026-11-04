-- ═══════════════════════════════════════════════════════════════
-- ShopFlow Migration — Staff Dashboard RPC
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.get_staff_dashboard_stats(
    p_shop_id UUID,
    p_staff_id TEXT,
    p_start_date TIMESTAMPTZ,
    p_end_date TIMESTAMPTZ
)
RETURNS JSON AS $$
DECLARE
    v_total_bills INT;
    v_total_sales NUMERIC;
    v_total_items INT;
    v_cash_sales NUMERIC;
    v_upi_sales NUMERIC;
    v_card_sales NUMERIC;
    v_completed INT;
    v_cancelled INT;
    v_returned INT;
    v_hourly_sales JSON;
    v_daily_sales JSON;
BEGIN
    -- Basic Security: If authenticated as owner, ensure they own the shop
    IF auth.uid() IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM public.shops WHERE id = p_shop_id AND owner_user_id = auth.uid()) THEN
            RAISE EXCEPTION 'Unauthorized';
        END IF;
    END IF;

    -- Aggregate totals for the staff member within the date range
    SELECT 
        COUNT(*),
        COALESCE(SUM(grand_total), 0),
        COALESCE(SUM(CASE WHEN payment_method ILIKE 'cash' THEN grand_total ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN payment_method ILIKE 'upi' THEN grand_total ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN payment_method ILIKE 'card' THEN grand_total ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN status ILIKE 'completed' THEN 1 ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN status ILIKE 'cancelled' THEN 1 ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN status ILIKE 'returned' THEN 1 ELSE 0 END), 0)
    INTO 
        v_total_bills, v_total_sales, v_cash_sales, v_upi_sales, v_card_sales,
        v_completed, v_cancelled, v_returned
    FROM public.bills
    WHERE shop_id = p_shop_id 
      AND staff_id = p_staff_id
      AND created_at >= p_start_date
      AND created_at <= p_end_date;

    -- Total Items Sold (join with bill_items)
    SELECT COALESCE(SUM(bi.quantity), 0)
    INTO v_total_items
    FROM public.bill_items bi
    JOIN public.bills b ON bi.bill_id = b.id
    WHERE b.shop_id = p_shop_id 
      AND b.staff_id = p_staff_id
      AND b.created_at >= p_start_date
      AND b.created_at <= p_end_date
      AND b.status ILIKE 'completed';

    -- Hourly Chart (grouped by hour) for "Today" view
    SELECT json_agg(row_to_json(t)) INTO v_hourly_sales
    FROM (
        SELECT 
            EXTRACT(HOUR FROM created_at) AS hour,
            COALESCE(SUM(grand_total), 0) AS total_sales,
            COUNT(*) AS bill_count
        FROM public.bills
        WHERE shop_id = p_shop_id 
          AND staff_id = p_staff_id
          AND created_at >= p_start_date
          AND created_at <= p_end_date
        GROUP BY EXTRACT(HOUR FROM created_at)
        ORDER BY hour
    ) t;

    -- Daily Chart (grouped by date) for "This Week/Month" view
    SELECT json_agg(row_to_json(t)) INTO v_daily_sales
    FROM (
        SELECT 
            DATE(created_at) AS date,
            COALESCE(SUM(grand_total), 0) AS total_sales,
            COUNT(*) AS bill_count
        FROM public.bills
        WHERE shop_id = p_shop_id 
          AND staff_id = p_staff_id
          AND created_at >= p_start_date
          AND created_at <= p_end_date
        GROUP BY DATE(created_at)
        ORDER BY date
    ) t;

    RETURN json_build_object(
        'total_bills', v_total_bills,
        'total_sales', v_total_sales,
        'total_items', v_total_items,
        'cash_sales', v_cash_sales,
        'upi_sales', v_upi_sales,
        'card_sales', v_card_sales,
        'completed_bills', v_completed,
        'cancelled_bills', v_cancelled,
        'returned_bills', v_returned,
        'hourly_sales', COALESCE(v_hourly_sales, '[]'::json),
        'daily_sales', COALESCE(v_daily_sales, '[]'::json)
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.get_staff_dashboard_stats TO anon, authenticated;
