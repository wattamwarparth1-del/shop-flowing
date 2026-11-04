-- ═══════════════════════════════════════════════════════════════
-- ShopFlow Phase 5 — Database Migration (Final Phase)
-- Run this entire file in: Supabase Dashboard → SQL Editor → Run
-- ═══════════════════════════════════════════════════════════════

-- 1. ADD SETTINGS AND RECEIPT CUSTOMIZER COLUMNS TO SHOPS TABLE
ALTER TABLE public.shops 
  ADD COLUMN IF NOT EXISTS upi_id TEXT,
  ADD COLUMN IF NOT EXISTS upi_name TEXT,
  ADD COLUMN IF NOT EXISTS bank_details TEXT,
  ADD COLUMN IF NOT EXISTS fssai_license TEXT,
  ADD COLUMN IF NOT EXISTS default_gst_rate NUMERIC DEFAULT 0,
  ADD COLUMN IF NOT EXISTS default_discount NUMERIC DEFAULT 0,
  ADD COLUMN IF NOT EXISTS auto_print BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS receipt_header_text TEXT DEFAULT 'Thank you for shopping with us!',
  ADD COLUMN IF NOT EXISTS receipt_footer_text TEXT DEFAULT 'No return without bill within 7 days.',
  ADD COLUMN IF NOT EXISTS receipt_paper_size TEXT DEFAULT '80mm',
  ADD COLUMN IF NOT EXISTS receipt_config JSONB DEFAULT '{
    "show_logo": true,
    "show_name": true,
    "show_address": true,
    "show_phone": true,
    "show_gst": true,
    "show_pos": true,
    "show_staff": true,
    "show_customer": true,
    "show_hsn": false,
    "show_gst_col": true,
    "show_disc_col": true,
    "show_upi_qr": true,
    "show_subtotal": true,
    "show_words": false
  }'::jsonb;

-- 2. FUNCTION TO GET FULL SHOP BACKUP IN A SINGLE JSON OBJECT
CREATE OR REPLACE FUNCTION public.get_shop_full_backup(p_shop_id UUID)
RETURNS JSON AS $$
DECLARE
  v_result JSON;
BEGIN
  SELECT json_build_object(
    'export_date', NOW(),
    'shop_info', (SELECT row_to_json(s) FROM public.shops s WHERE s.id = p_shop_id),
    'staff_members', (SELECT COALESCE(json_agg(row_to_json(st)), '[]'::json) FROM public.staff_members st WHERE st.shop_id = p_shop_id),
    'billing_machines', (SELECT COALESCE(json_agg(row_to_json(m)), '[]'::json) FROM public.billing_machines m WHERE m.shop_id = p_shop_id),
    'products', (SELECT COALESCE(json_agg(row_to_json(p)), '[]'::json) FROM public.products p WHERE p.shop_id = p_shop_id),
    'customers', (SELECT COALESCE(json_agg(row_to_json(c)), '[]'::json) FROM public.customers c WHERE c.shop_id = p_shop_id),
    'bills', (SELECT COALESCE(json_agg(row_to_json(b)), '[]'::json) FROM public.bills b WHERE b.shop_id = p_shop_id),
    'stock_movements', (SELECT COALESCE(json_agg(row_to_json(sm)), '[]'::json) FROM public.stock_movements sm WHERE sm.shop_id = p_shop_id)
  ) INTO v_result;

  RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
