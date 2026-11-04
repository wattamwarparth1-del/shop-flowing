-- ═══════════════════════════════════════════════════════════════
-- ShopFlow Migration — Production-Ready Barcode System
-- Safe, idempotent, non-breaking migration for all shop models
-- Run in: Supabase Dashboard → SQL Editor → Run
-- ═══════════════════════════════════════════════════════════════

-- 1. Ensure barcode column exists on products (nullable for existing products)
ALTER TABLE public.products 
ADD COLUMN IF NOT EXISTS barcode TEXT;

-- 2. Add barcode_format column to store standard (CODE128, EAN13, UPCA, EAN8, etc.)
ALTER TABLE public.products 
ADD COLUMN IF NOT EXISTS barcode_format TEXT DEFAULT 'CODE128';

-- 3. Create safe partial unique index on (shop_id, barcode)
-- Only non-null, non-empty barcodes are constrained to be unique within a shop.
-- This guarantees uniqueness within the shop while safely preserving existing products that have no barcode.
CREATE UNIQUE INDEX IF NOT EXISTS idx_products_shop_barcode_unique 
ON public.products (shop_id, barcode) 
WHERE barcode IS NOT NULL AND barcode != '';

-- 4. Fast case-insensitive index for scanner lookup
CREATE INDEX IF NOT EXISTS idx_products_shop_barcode_lookup 
ON public.products (shop_id, lower(barcode)) 
WHERE barcode IS NOT NULL AND barcode != '';

-- 5. Atomic sequence counter table for internal barcode generation to prevent race conditions
CREATE TABLE IF NOT EXISTS public.shop_barcode_sequences (
  shop_id UUID PRIMARY KEY REFERENCES public.shops(id) ON DELETE CASCADE,
  next_seq BIGINT NOT NULL DEFAULT 1001,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Enable RLS on barcode sequences
ALTER TABLE public.shop_barcode_sequences ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Strict shop isolation for barcode sequences" ON public.shop_barcode_sequences;
CREATE POLICY "Strict shop isolation for barcode sequences" ON public.shop_barcode_sequences
  FOR ALL USING (public.is_authorized_for_shop(shop_id));

-- 6. Atomic Stored Function to generate unique internal retail Code 128 barcode
CREATE OR REPLACE FUNCTION public.generate_shop_barcode(
  p_shop_id UUID,
  p_prefix TEXT DEFAULT 'SF'
)
RETURNS JSON AS $$
DECLARE
  v_shop_display TEXT;
  v_clean_num    TEXT;
  v_seq          BIGINT;
  v_candidate    TEXT;
  v_sum          INT;
  v_check_digit  INT;
  v_i            INT;
  v_char_code    INT;
  v_attempts     INT := 0;
BEGIN
  -- Verify shop authorization
  IF NOT public.is_authorized_for_shop(p_shop_id) THEN
    RETURN json_build_object('success', false, 'error', 'Unauthorized access to shop');
  END IF;

  -- Get shop display ID to construct shop-specific prefix
  SELECT COALESCE(owner_display_id, '10001') INTO v_shop_display
  FROM public.shops WHERE id = p_shop_id;

  -- Extract numeric portion or use substring
  v_clean_num := REGEXP_REPLACE(v_shop_display, '[^0-9]', '', 'g');
  IF v_clean_num = '' OR v_clean_num IS NULL THEN
    v_clean_num := '10001';
  END IF;
  IF LENGTH(v_clean_num) > 5 THEN
    v_clean_num := SUBSTRING(v_clean_num FROM 1 FOR 5);
  ELSE
    v_clean_num := LPAD(v_clean_num, 5, '0');
  END IF;

  -- Atomic increment of sequence
  INSERT INTO public.shop_barcode_sequences (shop_id, next_seq, updated_at)
  VALUES (p_shop_id, 1001, NOW())
  ON CONFLICT (shop_id) DO UPDATE 
    SET next_seq = public.shop_barcode_sequences.next_seq + 1,
        updated_at = NOW()
  RETURNING next_seq INTO v_seq;

  -- Loop to guarantee candidate barcode does not collide with any manual barcodes
  LOOP
    v_attempts := v_attempts + 1;
    IF v_attempts > 100 THEN
      -- Fallback to high-entropy unique code
      v_candidate := p_prefix || v_clean_num || '-' || LPAD((v_seq + v_attempts)::TEXT, 6, '0');
      EXIT;
    END IF;

    -- Standard Retail Code 128 representation: SF + [ShopNum] - [Sequence 5-digit]
    v_candidate := p_prefix || v_clean_num || '-' || LPAD(v_seq::TEXT, 5, '0');

    -- Calculate Luhn / Mod 10 check digit for the candidate
    v_sum := 0;
    FOR v_i IN 1..LENGTH(v_candidate) LOOP
      v_char_code := ASCII(SUBSTRING(v_candidate FROM v_i FOR 1));
      v_sum := v_sum + (v_char_code * (v_i % 3 + 1));
    END LOOP;
    v_check_digit := (10 - (v_sum % 10)) % 10;
    v_candidate := v_candidate || v_check_digit::TEXT;

    -- Check if candidate already exists in this shop
    IF NOT EXISTS (
      SELECT 1 FROM public.products 
      WHERE shop_id = p_shop_id AND barcode = v_candidate
    ) THEN
      EXIT;
    END IF;

    -- Collision encountered, increment sequence
    v_seq := v_seq + 1;
  END LOOP;

  RETURN json_build_object(
    'success', true,
    'barcode', v_candidate,
    'format', 'CODE128'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 7. Stored Function to check barcode availability for a shop
CREATE OR REPLACE FUNCTION public.check_barcode_available(
  p_shop_id UUID,
  p_barcode TEXT,
  p_product_id UUID DEFAULT NULL
)
RETURNS JSON AS $$
DECLARE
  v_exists BOOLEAN;
  v_existing_name TEXT;
BEGIN
  IF NOT public.is_authorized_for_shop(p_shop_id) THEN
    RETURN json_build_object('success', false, 'error', 'Unauthorized');
  END IF;

  SELECT name INTO v_existing_name
  FROM public.products
  WHERE shop_id = p_shop_id 
    AND LOWER(barcode) = LOWER(TRIM(p_barcode))
    AND (p_product_id IS NULL OR id != p_product_id)
  LIMIT 1;

  IF v_existing_name IS NOT NULL THEN
    RETURN json_build_object(
      'available', false,
      'error', 'Barcode already assigned to product: ' || v_existing_name
    );
  END IF;

  RETURN json_build_object('available', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 8. Stored Function to assign or regenerate product barcode with permission enforcement & audit logging
CREATE OR REPLACE FUNCTION public.assign_product_barcode(
  p_shop_id UUID,
  p_product_id UUID,
  p_barcode TEXT,
  p_format TEXT DEFAULT 'CODE128',
  p_actor_id TEXT DEFAULT NULL,
  p_actor_name TEXT DEFAULT NULL,
  p_actor_role TEXT DEFAULT NULL,
  p_reason TEXT DEFAULT NULL
)
RETURNS JSON AS $$
DECLARE
  v_prod RECORD;
  v_existing_name TEXT;
  v_clean_barcode TEXT;
  v_clean_format TEXT;
  v_is_owner BOOLEAN;
  v_is_manager BOOLEAN;
BEGIN
  -- Check multi-tenant authorization
  IF NOT public.is_authorized_for_shop(p_shop_id) THEN
    RETURN json_build_object('success', false, 'error', 'Unauthorized access to this shop.');
  END IF;

  -- Enforce role permissions: only Owner or Manager can modify barcodes
  v_is_owner := (auth.uid() IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.shops WHERE id = p_shop_id AND owner_user_id = auth.uid()
  )) OR (LOWER(COALESCE(p_actor_role, '')) = 'owner');

  v_is_manager := (LOWER(COALESCE(p_actor_role, '')) = 'manager');

  IF NOT (v_is_owner OR v_is_manager) THEN
    RETURN json_build_object(
      'success', false, 
      'error', 'Permission denied: Staff members cannot modify product barcodes. Only Owners and Managers are permitted.'
    );
  END IF;

  -- Fetch product
  SELECT * INTO v_prod FROM public.products 
  WHERE id = p_product_id AND shop_id = p_shop_id;
  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'error', 'Product not found in this shop.');
  END IF;

  v_clean_barcode := TRIM(p_barcode);
  v_clean_format := UPPER(COALESCE(p_format, 'CODE128'));

  IF v_clean_barcode = '' THEN
    RETURN json_build_object('success', false, 'error', 'Barcode cannot be empty.');
  END IF;

  -- Check if another product already uses this barcode in the same shop
  SELECT name INTO v_existing_name 
  FROM public.products 
  WHERE shop_id = p_shop_id 
    AND LOWER(barcode) = LOWER(v_clean_barcode) 
    AND id != p_product_id 
  LIMIT 1;

  IF v_existing_name IS NOT NULL THEN
    RETURN json_build_object(
      'success', false, 
      'error', 'Barcode "' || v_clean_barcode || '" is already assigned to product: ' || v_existing_name
    );
  END IF;

  -- Update product barcode safely without affecting stock, price, sales, or invoices
  UPDATE public.products 
  SET barcode = v_clean_barcode,
      barcode_format = v_clean_format,
      updated_at = NOW()
  WHERE id = p_product_id AND shop_id = p_shop_id;

  -- Record audit log entry
  INSERT INTO public.audit_logs (
    shop_id, actor_id, actor_name, actor_role, action, category,
    resource_type, resource_id, resource_name, result, reason,
    before_data, after_data, changed_fields
  ) VALUES (
    p_shop_id,
    COALESCE(p_actor_id, 'system'),
    COALESCE(p_actor_name, 'System'),
    COALESCE(p_actor_role, 'owner'),
    CASE WHEN v_prod.barcode IS NULL OR v_prod.barcode = '' THEN 'product.barcode_assigned' ELSE 'product.barcode_regenerated' END,
    'Inventory',
    'products',
    p_product_id::TEXT,
    v_prod.name,
    'SUCCESS',
    COALESCE(p_reason, 'Barcode assigned or regenerated'),
    json_build_object('barcode', v_prod.barcode, 'barcode_format', v_prod.barcode_format),
    json_build_object('barcode', v_clean_barcode, 'barcode_format', v_clean_format),
    json_build_array('barcode', 'barcode_format')
  );

  RETURN json_build_object(
    'success', true,
    'barcode', v_clean_barcode,
    'barcode_format', v_clean_format,
    'message', 'Barcode assigned successfully.'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 9. Stored Function for Secure Barcode Lookup during Billing (strict shop isolation)
CREATE OR REPLACE FUNCTION public.lookup_product_by_barcode(
  p_shop_id UUID,
  p_barcode TEXT
)
RETURNS JSON AS $$
DECLARE
  v_prod RECORD;
BEGIN
  IF NOT public.is_authorized_for_shop(p_shop_id) THEN
    RETURN json_build_object('success', false, 'error', 'Unauthorized');
  END IF;

  SELECT * INTO v_prod FROM public.products
  WHERE shop_id = p_shop_id
    AND (
      LOWER(barcode) = LOWER(TRIM(p_barcode))
      OR (sku IS NOT NULL AND LOWER(sku) = LOWER(TRIM(p_barcode)))
    )
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN json_build_object(
      'success', false, 
      'error', 'Product not found in this shop for barcode: ' || p_barcode
    );
  END IF;

  RETURN json_build_object(
    'success', true,
    'product', row_to_json(v_prod)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 10. Permissions
GRANT EXECUTE ON FUNCTION public.generate_shop_barcode TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.check_barcode_available TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assign_product_barcode TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.lookup_product_by_barcode TO anon, authenticated;

-- 11. Notify PostgREST to reload schema
NOTIFY pgrst, 'reload schema';
