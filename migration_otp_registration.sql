-- ═══════════════════════════════════════════════════════════════
-- ShopFlow Migration — 6-Digit Email OTP & Verified Registration
-- Run in: Supabase Dashboard → SQL Editor → Run
-- ═══════════════════════════════════════════════════════════════

-- 1. Helper function to check if an email is already registered with a shop
CREATE OR REPLACE FUNCTION public.check_registration_email_available(p_email TEXT)
RETURNS JSONB AS $$
DECLARE
  v_clean_email TEXT;
  v_exists_in_shops BOOLEAN;
  v_exists_in_users BOOLEAN;
BEGIN
  v_clean_email := LOWER(TRIM(p_email));
  
  IF v_clean_email IS NULL OR v_clean_email = '' OR v_clean_email NOT LIKE '%@%.%' THEN
    RETURN jsonb_build_object('available', false, 'error', 'Invalid email format.');
  END IF;

  -- Check if an active shop exists with this email
  SELECT EXISTS(SELECT 1 FROM public.shops WHERE LOWER(email) = v_clean_email) INTO v_exists_in_shops;
  
  -- Check if a user with confirmed email already exists
  SELECT EXISTS(
    SELECT 1 FROM auth.users 
    WHERE LOWER(email) = v_clean_email 
      AND (email_confirmed_at IS NOT NULL OR confirmed_at IS NOT NULL)
  ) INTO v_exists_in_users;

  IF v_exists_in_shops OR v_exists_in_users THEN
    RETURN jsonb_build_object(
      'available', false, 
      'error', 'An account with this email already exists. Please log in.'
    );
  END IF;

  RETURN jsonb_build_object('available', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.check_registration_email_available(TEXT) TO anon, authenticated;


-- 2. Complete Owner Registration RPC
-- Strictly executes only when the user's email is confirmed in auth.users!
CREATE OR REPLACE FUNCTION public.complete_owner_registration(
  p_name TEXT,
  p_mobile TEXT,
  p_shop_name TEXT,
  p_shop_type TEXT,
  p_custom_type_description TEXT DEFAULT NULL,
  p_business_modules JSONB DEFAULT NULL,
  p_gst_number TEXT DEFAULT NULL,
  p_address TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_user_id       UUID;
  v_user_email    TEXT;
  v_is_confirmed  BOOLEAN;
  v_shop_id       UUID;
  v_owner_id      TEXT;
  v_modules       JSONB;
BEGIN
  -- 1. Ensure caller is authenticated via Supabase Auth
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required. Please verify your email first.';
  END IF;

  -- 2. Verify that email is confirmed in auth.users
  SELECT email, (email_confirmed_at IS NOT NULL OR confirmed_at IS NOT NULL)
  INTO v_user_email, v_is_confirmed
  FROM auth.users
  WHERE id = v_user_id;

  IF NOT COALESCE(v_is_confirmed, false) THEN
    RAISE EXCEPTION 'Email verification required. Please verify your email with the 6-digit OTP before completing registration.';
  END IF;

  -- 3. Prepare business modules
  v_modules := COALESCE(p_business_modules, '{
    "standard_billing": true,
    "inventory_suppliers": true,
    "returns_refunds": true
  }'::jsonb);

  -- 4. Check if shop already exists for this owner
  SELECT id, owner_display_id INTO v_shop_id, v_owner_id
  FROM public.shops
  WHERE owner_user_id = v_user_id;

  IF v_shop_id IS NOT NULL THEN
    -- Update existing shop record
    UPDATE public.shops
    SET
      name = COALESCE(NULLIF(TRIM(p_shop_name), ''), name),
      type = COALESCE(NULLIF(TRIM(p_shop_type), ''), type),
      custom_type_description = p_custom_type_description,
      business_modules = v_modules,
      phone = COALESCE(NULLIF(TRIM(p_mobile), ''), phone),
      gst_number = p_gst_number,
      address = p_address,
      email = v_user_email,
      updated_at = NOW()
    WHERE id = v_shop_id;
  ELSE
    -- Generate new owner display ID (e.g. OWN-10025)
    v_owner_id := public.generate_owner_id();

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
      v_user_id,
      v_owner_id,
      COALESCE(NULLIF(TRIM(p_shop_name), ''), 'My Shop'),
      COALESCE(NULLIF(TRIM(p_shop_type), ''), 'General Store'),
      p_custom_type_description,
      v_modules,
      TRIM(p_mobile),
      p_gst_number,
      p_address,
      v_user_email
    )
    RETURNING id INTO v_shop_id;
  END IF;

  -- 5. Insert or update Profile
  INSERT INTO public.profiles (id, shop_id, name, mobile, role)
  VALUES (v_user_id, v_shop_id, COALESCE(NULLIF(TRIM(p_name), ''), 'Owner'), TRIM(p_mobile), 'owner')
  ON CONFLICT (id) DO UPDATE
  SET
    shop_id = EXCLUDED.shop_id,
    name = EXCLUDED.name,
    mobile = EXCLUDED.mobile;

  -- 6. Reload schema cache
  NOTIFY pgrst, 'reload schema';

  RETURN jsonb_build_object(
    'success', true,
    'shop_id', v_shop_id,
    'owner_display_id', v_owner_id,
    'shop_name', p_shop_name,
    'email', v_user_email
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.complete_owner_registration(TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT) TO authenticated;
