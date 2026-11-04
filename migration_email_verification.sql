-- ═══════════════════════════════════════════════════════════════
-- ShopFlow Migration — Strict Email Verification & RLS Security
-- ═══════════════════════════════════════════════════════════════

-- 1. Update RLS Helper function to enforce email verification for shop owners
CREATE OR REPLACE FUNCTION public.is_authorized_for_shop(p_shop_id UUID)
RETURNS BOOLEAN AS $$
DECLARE
    v_header TEXT;
BEGIN
    -- 1. If user is authenticated owner via Supabase Auth:
    -- Verify that the user owns the shop AND has a confirmed email in auth.users
    IF auth.uid() IS NOT NULL THEN
        RETURN EXISTS (
            SELECT 1 FROM public.shops s
            JOIN auth.users u ON u.id = s.owner_user_id
            WHERE s.id = p_shop_id 
              AND s.owner_user_id = auth.uid()
              AND (u.email_confirmed_at IS NOT NULL OR u.confirmed_at IS NOT NULL)
        );
    END IF;

    -- 2. If user is anon staff, check for custom header token passed by frontend
    BEGIN
        v_header := current_setting('request.headers', true)::json->>'x-staff-token';
    EXCEPTION WHEN OTHERS THEN
        v_header := NULL;
    END;

    IF v_header IS NOT NULL AND v_header != '' THEN
        RETURN EXISTS (
            SELECT 1 FROM public.staff_sessions ss
            WHERE ss.token = v_header::uuid
              AND ss.shop_id = p_shop_id
              AND ss.expires_at > NOW()
        );
    END IF;

    RETURN FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2. Helper RPC for checking if an email is confirmed (safe check for verification polling)
CREATE OR REPLACE FUNCTION public.is_email_verified(p_email TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    IF p_email IS NULL OR TRIM(p_email) = '' THEN
        RETURN FALSE;
    END IF;

    RETURN EXISTS (
        SELECT 1 FROM auth.users
        WHERE LOWER(email) = LOWER(TRIM(p_email))
          AND (email_confirmed_at IS NOT NULL OR confirmed_at IS NOT NULL)
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.is_email_verified(TEXT) TO anon, authenticated;

-- 3. Notify PostgREST to reload schema cache
NOTIFY pgrst, 'reload schema';
