-- ═══════════════════════════════════════════════════════════════
-- ShopFlow Migration — Add Flexible Staff Roles (Cashier, Cleaner, Manager, Staff)
-- Run this in Supabase Dashboard → SQL Editor → Run
-- ═══════════════════════════════════════════════════════════════

-- 1. Drop existing role constraint if present
ALTER TABLE public.staff_members DROP CONSTRAINT IF EXISTS staff_members_role_check;

-- 2. Update create_staff_member function to allow cashier, cleaner, manager, staff
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

  IF EXISTS (
    SELECT 1 FROM public.staff_members
    WHERE shop_id = p_shop_id AND staff_display_id = UPPER(TRIM(p_staff_display_id))
  ) THEN
    RETURN json_build_object('success', false, 'error', 'Staff ID already exists in your shop.');
  END IF;

  INSERT INTO public.staff_members
    (shop_id, staff_display_id, name, mobile, email, role, password_hash, pos_id)
  VALUES
    (p_shop_id, UPPER(TRIM(p_staff_display_id)), p_name, p_mobile, p_email, LOWER(TRIM(p_role)),
     crypt(p_password, gen_salt('bf')), p_pos_id);

  RETURN json_build_object('success', true, 'message', 'Staff member created successfully.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
