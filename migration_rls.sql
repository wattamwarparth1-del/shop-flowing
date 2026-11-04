-- ═══════════════════════════════════════════════════════════════
-- ShopFlow Migration — Strict Row Level Security & Multi-Tenancy
-- ═══════════════════════════════════════════════════════════════

-- 1. Create a secure session table for staff (pseudo-auth)
CREATE TABLE IF NOT EXISTS public.staff_sessions (
    token UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    staff_id UUID NOT NULL REFERENCES public.staff_members(id) ON DELETE CASCADE,
    shop_id UUID NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    expires_at TIMESTAMPTZ DEFAULT NOW() + INTERVAL '24 hours'
);

CREATE INDEX IF NOT EXISTS idx_staff_sessions_token ON public.staff_sessions(token);

-- Secure the sessions table so only server-side RPCs can read/write to it
ALTER TABLE public.staff_sessions ENABLE ROW LEVEL SECURITY;
-- (No policies attached: completely inaccessible from the client side)

-- 2. Update verify_staff_login to issue a session token
CREATE OR REPLACE FUNCTION public.verify_staff_login(
  p_owner_display_id TEXT,
  p_staff_display_id TEXT,
  p_password         TEXT
)
RETURNS JSON AS $$
DECLARE
  v_shop  RECORD;
  v_staff RECORD;
  v_token UUID;
BEGIN
  SELECT * INTO v_shop FROM public.shops
  WHERE owner_display_id = UPPER(TRIM(p_owner_display_id));
  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'error', 'Invalid Owner ID.');
  END IF;

  SELECT * INTO v_staff FROM public.staff_members
  WHERE shop_id = v_shop.id
    AND staff_display_id = UPPER(TRIM(p_staff_display_id))
    AND is_active = TRUE;
  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'error', 'Staff ID not found or account is inactive.');
  END IF;

  IF v_staff.password_hash != crypt(p_password, v_staff.password_hash) THEN
    RETURN json_build_object('success', false, 'error', 'Incorrect password.');
  END IF;

  -- Generate secure session token
  v_token := gen_random_uuid();
  INSERT INTO public.staff_sessions (token, staff_id, shop_id)
  VALUES (v_token, v_staff.id, v_shop.id);

  RETURN json_build_object(
    'success',           true,
    'staff_token',       v_token,
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

-- 3. Create RPC to clear session token on logout
CREATE OR REPLACE FUNCTION public.logout_staff(p_token UUID)
RETURNS VOID AS $$
BEGIN
    DELETE FROM public.staff_sessions WHERE token = p_token;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.logout_staff TO anon, authenticated;

-- 4. Create an RLS Helper Function to reduce repetition
CREATE OR REPLACE FUNCTION public.is_authorized_for_shop(p_shop_id UUID)
RETURNS BOOLEAN AS $$
DECLARE
    v_header TEXT;
BEGIN
    -- 1. If user is authenticated owner via Supabase Auth
    IF auth.uid() IS NOT NULL THEN
        RETURN EXISTS (SELECT 1 FROM public.shops WHERE id = p_shop_id AND owner_user_id = auth.uid());
    END IF;

    -- 2. If user is anon staff, check for custom header token passed by our frontend
    BEGIN
        v_header := current_setting('request.headers', true)::json->>'x-staff-token';
    EXCEPTION WHEN OTHERS THEN
        v_header := NULL;
    END;

    IF v_header IS NOT NULL AND v_header != '' THEN
        RETURN EXISTS (
            SELECT 1 FROM public.staff_sessions 
            WHERE token::text = v_header 
              AND shop_id = p_shop_id 
              AND expires_at > NOW()
        );
    END IF;

    RETURN false;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 5. Apply Strict Multi-Tenant RLS to all business tables

-- Products
DROP POLICY IF EXISTS "Shop access products" ON public.products;
CREATE POLICY "Strict Shop isolation for products" ON public.products
    FOR ALL USING (public.is_authorized_for_shop(shop_id));

-- Customers
DROP POLICY IF EXISTS "Shop access customers" ON public.customers;
CREATE POLICY "Strict Shop isolation for customers" ON public.customers
    FOR ALL USING (public.is_authorized_for_shop(shop_id));

-- Bills
DROP POLICY IF EXISTS "Shop access bills" ON public.bills;
CREATE POLICY "Strict Shop isolation for bills" ON public.bills
    FOR ALL USING (public.is_authorized_for_shop(shop_id));

-- Bill Items
DROP POLICY IF EXISTS "Shop access bill_items" ON public.bill_items;
CREATE POLICY "Strict Shop isolation for bill_items" ON public.bill_items
    FOR ALL USING (public.is_authorized_for_shop(shop_id));

-- Stock Movements
DROP POLICY IF EXISTS "Shop access stock_movements" ON public.stock_movements;
CREATE POLICY "Strict Shop isolation for stock_movements" ON public.stock_movements
    FOR ALL USING (public.is_authorized_for_shop(shop_id));

-- Audit Logs
DROP POLICY IF EXISTS "Enable read for shop audit" ON public.audit_logs;
DROP POLICY IF EXISTS "Enable insert for shop audit" ON public.audit_logs;
CREATE POLICY "Strict Shop isolation for audit select" ON public.audit_logs
    FOR SELECT USING (public.is_authorized_for_shop(shop_id));
CREATE POLICY "Strict Shop isolation for audit insert" ON public.audit_logs
    FOR INSERT WITH CHECK (public.is_authorized_for_shop(shop_id));

-- Staff Members
DROP POLICY IF EXISTS "Owner manages own shop staff" ON public.staff_members;
CREATE POLICY "Strict Shop isolation for staff_members" ON public.staff_members
    FOR ALL USING (public.is_authorized_for_shop(shop_id));

-- Billing Machines
DROP POLICY IF EXISTS "Owner manages own machines" ON public.billing_machines;
CREATE POLICY "Strict Shop isolation for billing_machines" ON public.billing_machines
    FOR ALL USING (public.is_authorized_for_shop(shop_id));

-- Customer Messages (Engagement)
DROP POLICY IF EXISTS "Shop access messages" ON public.customer_messages;
CREATE POLICY "Strict Shop isolation for customer_messages" ON public.customer_messages
    FOR ALL USING (public.is_authorized_for_shop(shop_id));

-- Announcements (from Phase 5)
DROP POLICY IF EXISTS "Shop access announcements" ON public.announcements;
CREATE POLICY "Strict Shop isolation for announcements" ON public.announcements
    FOR ALL USING (public.is_authorized_for_shop(shop_id));
