-- ═══════════════════════════════════════════════════════════════
-- ShopFlow Phase 2 — Database Migration
-- Run this entire file in: Supabase Dashboard → SQL Editor → Run
-- ═══════════════════════════════════════════════════════════════

-- 1. Enable pgcrypto for password hashing
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 2. SHOPS TABLE
CREATE TABLE IF NOT EXISTS public.shops (
  id                UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  owner_user_id     UUID REFERENCES auth.users(id) ON DELETE CASCADE UNIQUE,
  owner_display_id  TEXT UNIQUE,
  name              TEXT NOT NULL,
  type              TEXT DEFAULT 'General Store',
  address           TEXT,
  city              TEXT,
  state             TEXT,
  pin_code          TEXT,
  gst_number        TEXT,
  pan_number        TEXT,
  phone             TEXT,
  email             TEXT,
  bill_prefix       TEXT DEFAULT 'INV',
  next_bill_number  INTEGER DEFAULT 1,
  created_at        TIMESTAMPTZ DEFAULT NOW()
);

-- 3. PROFILES TABLE (one per owner, links auth.users → shops)
CREATE TABLE IF NOT EXISTS public.profiles (
  id          UUID REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
  shop_id     UUID REFERENCES public.shops(id) ON DELETE CASCADE,
  name        TEXT,
  mobile      TEXT,
  role        TEXT DEFAULT 'owner',
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- 4. STAFF MEMBERS TABLE
CREATE TABLE IF NOT EXISTS public.staff_members (
  id                UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  shop_id           UUID REFERENCES public.shops(id) ON DELETE CASCADE,
  staff_display_id  TEXT NOT NULL,
  name              TEXT NOT NULL,
  mobile            TEXT,
  email             TEXT,
  role              TEXT NOT NULL CHECK (role IN ('manager', 'staff')),
  password_hash     TEXT NOT NULL,
  pos_id            TEXT,
  is_active         BOOLEAN DEFAULT TRUE,
  created_at        TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(shop_id, staff_display_id)
);

-- 5. BILLING MACHINES TABLE
CREATE TABLE IF NOT EXISTS public.billing_machines (
  id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  shop_id         UUID REFERENCES public.shops(id) ON DELETE CASCADE,
  machine_code    TEXT NOT NULL,
  machine_name    TEXT,
  is_active       BOOLEAN DEFAULT TRUE,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(shop_id, machine_code)
);

-- ───────────────────────────────────────────────────────────────
-- FUNCTIONS
-- ───────────────────────────────────────────────────────────────

-- 6. Generate unique owner ID (OWN-XXXXX)
CREATE OR REPLACE FUNCTION public.generate_owner_id()
RETURNS TEXT AS $$
DECLARE
  new_id TEXT;
  num    INT;
BEGIN
  SELECT COALESCE(MAX(CAST(SUBSTRING(owner_display_id FROM 5) AS INT)), 10000) + 1
  INTO num FROM public.shops WHERE owner_display_id ~ '^OWN-[0-9]+$';
  new_id := 'OWN-' || LPAD(num::TEXT, 5, '0');
  WHILE EXISTS (SELECT 1 FROM public.shops WHERE owner_display_id = new_id) LOOP
    num := num + 1;
    new_id := 'OWN-' || LPAD(num::TEXT, 5, '0');
  END LOOP;
  RETURN new_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 7. Auto-create shop + profile when a new owner signs up
CREATE OR REPLACE FUNCTION public.handle_new_owner()
RETURNS TRIGGER AS $$
DECLARE
  v_shop_id    UUID;
  v_owner_id   TEXT;
  v_shop_name  TEXT;
  v_shop_type  TEXT;
  v_name       TEXT;
BEGIN
  v_shop_name := COALESCE(NEW.raw_user_meta_data->>'shop_name', 'My Shop');
  v_shop_type := COALESCE(NEW.raw_user_meta_data->>'shop_type', 'General Store');
  v_name      := COALESCE(NEW.raw_user_meta_data->>'name', 'Owner');
  v_owner_id  := public.generate_owner_id();

  INSERT INTO public.shops (owner_user_id, owner_display_id, name, type, email)
  VALUES (NEW.id, v_owner_id, v_shop_name, v_shop_type, NEW.email)
  RETURNING id INTO v_shop_id;

  INSERT INTO public.profiles (id, shop_id, name, role)
  VALUES (NEW.id, v_shop_id, v_name, 'owner');

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 8. Trigger: fires when owner signs up
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_owner();

-- 9. Verify staff login credentials and return session data
CREATE OR REPLACE FUNCTION public.verify_staff_login(
  p_owner_display_id TEXT,
  p_staff_display_id TEXT,
  p_password         TEXT
)
RETURNS JSON AS $$
DECLARE
  v_shop  RECORD;
  v_staff RECORD;
BEGIN
  SELECT * INTO v_shop FROM public.shops
  WHERE owner_display_id = UPPER(TRIM(p_owner_display_id));
  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'error', 'Invalid Owner ID. Check with your shop owner.');
  END IF;

  SELECT * INTO v_staff FROM public.staff_members
  WHERE shop_id = v_shop.id
    AND staff_display_id = UPPER(TRIM(p_staff_display_id))
    AND is_active = TRUE;
  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'error', 'Staff ID not found or account is inactive.');
  END IF;

  IF v_staff.password_hash != crypt(p_password, v_staff.password_hash) THEN
    RETURN json_build_object('success', false, 'error', 'Incorrect password. Please try again.');
  END IF;

  RETURN json_build_object(
    'success',           true,
    'staff_id',          v_staff.id,
    'staff_display_id',  v_staff.staff_display_id,
    'name',              v_staff.name,
    'role',              v_staff.role,
    'shop_id',           v_shop.id,
    'shop_name',         v_shop.name,
    'owner_display_id',  v_shop.owner_display_id,
    'pos_id',            v_staff.pos_id
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 10. Create a staff member (called by owner; hashes password server-side)
CREATE OR REPLACE FUNCTION public.create_staff_member(
  p_shop_id         UUID,
  p_staff_display_id TEXT,
  p_name            TEXT,
  p_mobile          TEXT,
  p_email           TEXT,
  p_role            TEXT,
  p_password        TEXT,
  p_pos_id          TEXT DEFAULT NULL
)
RETURNS JSON AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.shops WHERE id = p_shop_id AND owner_user_id = auth.uid()
  ) THEN
    RETURN json_build_object('success', false, 'error', 'Unauthorized');
  END IF;

  IF p_role NOT IN ('manager', 'staff') THEN
    RETURN json_build_object('success', false, 'error', 'Invalid role. Must be manager or staff.');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.staff_members
    WHERE shop_id = p_shop_id AND staff_display_id = UPPER(TRIM(p_staff_display_id))
  ) THEN
    RETURN json_build_object('success', false, 'error', 'Staff ID already exists in your shop.');
  END IF;

  INSERT INTO public.staff_members
    (shop_id, staff_display_id, name, mobile, email, role, password_hash, pos_id)
  VALUES
    (p_shop_id, UPPER(TRIM(p_staff_display_id)), p_name, p_mobile, p_email, p_role,
     crypt(p_password, gen_salt('bf')), p_pos_id);

  RETURN json_build_object('success', true, 'message', 'Staff member created successfully.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ───────────────────────────────────────────────────────────────
-- ROW LEVEL SECURITY
-- ───────────────────────────────────────────────────────────────

ALTER TABLE public.shops ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.staff_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.billing_machines ENABLE ROW LEVEL SECURITY;

-- Shops policies
DROP POLICY IF EXISTS "Owner views own shop" ON public.shops;
CREATE POLICY "Owner views own shop" ON public.shops
  FOR SELECT USING (owner_user_id = auth.uid());

DROP POLICY IF EXISTS "Owner updates own shop" ON public.shops;
CREATE POLICY "Owner updates own shop" ON public.shops
  FOR UPDATE USING (owner_user_id = auth.uid());

-- Profiles policies
DROP POLICY IF EXISTS "Owner views own profile" ON public.profiles;
CREATE POLICY "Owner views own profile" ON public.profiles
  FOR SELECT USING (id = auth.uid());

DROP POLICY IF EXISTS "Owner updates own profile" ON public.profiles;
CREATE POLICY "Owner updates own profile" ON public.profiles
  FOR UPDATE USING (id = auth.uid());

-- Staff members policies
DROP POLICY IF EXISTS "Owner manages own shop staff" ON public.staff_members;
CREATE POLICY "Owner manages own shop staff" ON public.staff_members
  FOR ALL USING (
    shop_id IN (SELECT id FROM public.shops WHERE owner_user_id = auth.uid())
  );

-- Billing machines policies
DROP POLICY IF EXISTS "Owner manages own machines" ON public.billing_machines;
CREATE POLICY "Owner manages own machines" ON public.billing_machines
  FOR ALL USING (
    shop_id IN (SELECT id FROM public.shops WHERE owner_user_id = auth.uid())
  );

-- ───────────────────────────────────────────────────────────────
-- PERMISSIONS
-- ───────────────────────────────────────────────────────────────

-- Allow anonymous callers to invoke verify_staff_login (staff login screen)
GRANT EXECUTE ON FUNCTION public.verify_staff_login TO anon, authenticated;
-- create_staff_member is only used by authenticated owners
GRANT EXECUTE ON FUNCTION public.create_staff_member TO authenticated;
