-- ═══════════════════════════════════════════════════════════════
-- ShopFlow — Universal Shop Categories & Configurable Business Modules Migration
-- Safe, non-destructive migration. Run in: Supabase Dashboard → SQL Editor → Run
-- ═══════════════════════════════════════════════════════════════

-- 1. ADD COLUMNS FOR CUSTOM DESCRIPTION AND CONFIGURABLE MODULES
ALTER TABLE public.shops 
  ADD COLUMN IF NOT EXISTS custom_type_description TEXT,
  ADD COLUMN IF NOT EXISTS business_modules JSONB DEFAULT '{
    "standard_billing": true,
    "inventory_suppliers": true,
    "returns_refunds": true,
    "variants_barcodes": false,
    "batch_expiry": false,
    "serial_imei": false,
    "weight_scale": false,
    "service_charges": false,
    "appointments_orders": false,
    "restaurant_tables": false,
    "wholesale_pricing": false
  }'::jsonb;

-- 2. POPULATE EXISTING SHOPS WITHOUT MODULES WITH SENSIBLE DEFAULTS
UPDATE public.shops
SET business_modules = '{
  "standard_billing": true,
  "inventory_suppliers": true,
  "returns_refunds": true,
  "variants_barcodes": false,
  "batch_expiry": false,
  "serial_imei": false,
  "weight_scale": false,
  "service_charges": false,
  "appointments_orders": false,
  "restaurant_tables": false,
  "wholesale_pricing": false
}'::jsonb
WHERE business_modules IS NULL;

-- 3. UPDATE HANDLE_NEW_OWNER FUNCTION TO SUPPORT ALL CATEGORIES & MODULES
CREATE OR REPLACE FUNCTION public.handle_new_owner()
RETURNS TRIGGER AS $$
DECLARE
  v_shop_id       UUID;
  v_owner_id      TEXT;
  v_shop_name     TEXT;
  v_shop_type     TEXT;
  v_custom_desc   TEXT;
  v_modules       JSONB;
  v_name          TEXT;
  v_mobile        TEXT;
  v_gst           TEXT;
  v_address       TEXT;
BEGIN
  v_shop_name   := COALESCE(NEW.raw_user_meta_data->>'shop_name', 'My Shop');
  v_shop_type   := COALESCE(NEW.raw_user_meta_data->>'shop_type', 'General Store');
  v_custom_desc := NEW.raw_user_meta_data->>'custom_type_description';
  v_modules     := COALESCE(NEW.raw_user_meta_data->'business_modules', '{
    "standard_billing": true,
    "inventory_suppliers": true,
    "returns_refunds": true
  }'::jsonb);
  v_name        := COALESCE(NEW.raw_user_meta_data->>'name', 'Owner');
  v_mobile      := NEW.raw_user_meta_data->>'mobile';
  v_gst         := NEW.raw_user_meta_data->>'gst_number';
  v_address     := NEW.raw_user_meta_data->>'address';
  v_owner_id    := public.generate_owner_id();

  INSERT INTO public.shops (
    owner_user_id,
    owner_display_id,
    name,
    type,
    custom_type_description,
    business_modules,
    phone,
    gst_number,
    address,
    email
  )
  VALUES (
    NEW.id,
    v_owner_id,
    v_shop_name,
    v_shop_type,
    v_custom_desc,
    v_modules,
    v_mobile,
    v_gst,
    v_address,
    NEW.email
  )
  RETURNING id INTO v_shop_id;

  INSERT INTO public.profiles (id, shop_id, name, mobile, role)
  VALUES (NEW.id, v_shop_id, v_name, v_mobile, 'owner')
  ON CONFLICT (id) DO UPDATE 
  SET shop_id = EXCLUDED.shop_id,
      name = EXCLUDED.name,
      mobile = EXCLUDED.mobile;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 4. RE-ESTABLISH TRIGGER
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_owner();

-- 5. RELOAD SCHEMA CACHE
NOTIFY pgrst, 'reload schema';
