-- ═══════════════════════════════════════════════════════════════════════════
-- ShopFlow Migration — Production Low-Stock Email Notification System
-- Universal fix for ALL shop models (Jewellery, Paint, Grocery, Clothing, etc.)
-- Run in: Supabase Dashboard ➔ SQL Editor ➔ Run
-- ═══════════════════════════════════════════════════════════════════════════

-- 1. Enable Required Extensions
CREATE EXTENSION IF NOT EXISTS pg_net;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 2. Enhance stock_alerts Table with Delivery & Diagnostic Tracking
CREATE TABLE IF NOT EXISTS public.stock_alerts (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    shop_id UUID REFERENCES public.shops(id) ON DELETE CASCADE NOT NULL,
    product_id UUID REFERENCES public.products(id) ON DELETE CASCADE NOT NULL,
    status TEXT NOT NULL DEFAULT 'active', -- 'active' or 'resolved'
    created_at TIMESTAMPTZ DEFAULT NOW(),
    resolved_at TIMESTAMPTZ,
    resolved_by TEXT
);

ALTER TABLE public.stock_alerts
ADD COLUMN IF NOT EXISTS stock_at_alert NUMERIC(12,3),
ADD COLUMN IF NOT EXISTS min_stock_threshold NUMERIC(12,3),
ADD COLUMN IF NOT EXISTS product_name TEXT,
ADD COLUMN IF NOT EXISTS product_category TEXT,
ADD COLUMN IF NOT EXISTS product_unit TEXT DEFAULT 'pcs',
ADD COLUMN IF NOT EXISTS product_barcode TEXT,
ADD COLUMN IF NOT EXISTS recipient_email TEXT,
ADD COLUMN IF NOT EXISTS email_status TEXT NOT NULL DEFAULT 'pending', -- 'pending', 'sent', 'failed', 'skipped'
ADD COLUMN IF NOT EXISTS email_attempts INT NOT NULL DEFAULT 0,
ADD COLUMN IF NOT EXISTS last_attempt_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS email_sent_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS email_error TEXT,
ADD COLUMN IF NOT EXISTS request_id BIGINT;

CREATE INDEX IF NOT EXISTS idx_stock_alerts_shop_status ON public.stock_alerts(shop_id, status);
CREATE INDEX IF NOT EXISTS idx_stock_alerts_product_status ON public.stock_alerts(product_id, status);
CREATE INDEX IF NOT EXISTS idx_stock_alerts_email_status ON public.stock_alerts(email_status);

-- RLS for stock_alerts (allow all authenticated/anon to read for the UI)
ALTER TABLE public.stock_alerts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Shop access stock_alerts" ON public.stock_alerts;
CREATE POLICY "Shop access stock_alerts" ON public.stock_alerts FOR ALL USING (true);


-- 3. Secure Server-Side Notification Configuration Table
-- Strictly protected: API keys are NEVER exposed to browser or frontend code
CREATE TABLE IF NOT EXISTS public.notification_config (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    provider TEXT NOT NULL DEFAULT 'resend',
    api_key TEXT NOT NULL,
    sender_email TEXT NOT NULL DEFAULT 'ShopFlow Alerts <onboarding@resend.dev>',
    sender_name TEXT NOT NULL DEFAULT 'ShopFlow Alerts',
    app_url TEXT NOT NULL DEFAULT 'https://shop-flowing.netlify.app',
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Seed or update server-side email credentials safely
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.notification_config) THEN
        INSERT INTO public.notification_config (provider, api_key, sender_email, sender_name, app_url)
        VALUES (
            'resend',
            're_RPUUJjy2_JEQgbruL9FUNaMyh1eJmByY3',
            'ShopFlow Alerts <onboarding@resend.dev>',
            'ShopFlow Alerts',
            'https://shop-flowing.netlify.app'
        );
    ELSE
        UPDATE public.notification_config
        SET api_key = 're_RPUUJjy2_JEQgbruL9FUNaMyh1eJmByY3',
            sender_email = 'ShopFlow Alerts <onboarding@resend.dev>',
            app_url = 'https://shop-flowing.netlify.app',
            is_active = TRUE
        WHERE id = (SELECT id FROM public.notification_config LIMIT 1);
    END IF;
END $$;

-- Lock down notification_config table
ALTER TABLE public.notification_config ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.notification_config FROM anon, public;
GRANT ALL ON public.notification_config TO service_role;


-- 4. Server-Side Email Dispatcher RPC (SECURITY DEFINER)
-- Formats subject, HTML body, resolves recipient, and dispatches via net.http_post
CREATE OR REPLACE FUNCTION public.dispatch_stock_alert_email(p_alert_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net, extensions
AS $$
DECLARE
    v_alert        RECORD;
    v_config       RECORD;
    v_shop_name    TEXT;
    v_owner_email  TEXT;
    v_recipient    TEXT;
    v_subject      TEXT;
    v_html_body    TEXT;
    v_req_id       BIGINT;
    v_barcode_row  TEXT;
    v_stock_str    TEXT;
    v_min_str      TEXT;
    v_time_str     TEXT;
BEGIN
    -- 1. Fetch Alert Details with Tenant Isolation
    SELECT 
        a.*,
        s.name as shop_name,
        COALESCE(NULLIF(TRIM(s.email), ''), NULLIF(TRIM(u.email), '')) as resolved_email
    INTO v_alert
    FROM public.stock_alerts a
    JOIN public.shops s ON s.id = a.shop_id
    LEFT JOIN auth.users u ON u.id = s.owner_user_id
    WHERE a.id = p_alert_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Alert record not found.');
    END IF;

    -- 2. Idempotency Guard: Never resend if already sent
    IF v_alert.email_status = 'sent' THEN
        RETURN jsonb_build_object('success', true, 'status', 'already_sent');
    END IF;

    -- 3. Resolve and validate recipient email
    v_recipient := COALESCE(NULLIF(TRIM(v_alert.recipient_email), ''), v_alert.resolved_email);

    IF v_recipient IS NULL OR v_recipient = 'MISSING' OR v_recipient !~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' THEN
        UPDATE public.stock_alerts
        SET email_status = 'failed',
            last_attempt_at = NOW(),
            email_attempts = email_attempts + 1,
            email_error = 'Recipient email address missing or invalid for shop owner.'
        WHERE id = p_alert_id;

        RETURN jsonb_build_object('success', false, 'error', 'Missing or invalid recipient email');
    END IF;

    -- 4. Load Email Provider Configuration
    SELECT * INTO v_config
    FROM public.notification_config
    WHERE is_active = TRUE
    LIMIT 1;

    IF NOT FOUND OR v_config.api_key IS NULL OR v_config.api_key = '' THEN
        UPDATE public.stock_alerts
        SET email_status = 'failed',
            last_attempt_at = NOW(),
            email_attempts = email_attempts + 1,
            email_error = 'Email provider configuration missing in database.'
        WHERE id = p_alert_id;

        RETURN jsonb_build_object('success', false, 'error', 'Notification provider unconfigured');
    END IF;

    -- 5. Format Variables & Content
    v_shop_name := COALESCE(v_alert.shop_name, 'Your Shop');
    v_subject := 'Low Stock Alert — ' || v_alert.product_name;
    v_stock_str := TRIM(TO_CHAR(v_alert.stock_at_alert, 'FM999999990.###')) || ' ' || COALESCE(v_alert.product_unit, 'pcs');
    v_min_str := TRIM(TO_CHAR(v_alert.min_stock_threshold, 'FM999999990.###')) || ' ' || COALESCE(v_alert.product_unit, 'pcs');
    v_time_str := TO_CHAR(NOW() AT TIME ZONE 'Asia/Kolkata', 'DD Mon YYYY, HH12:MI AM') || ' IST';

    IF v_alert.product_barcode IS NOT NULL AND v_alert.product_barcode != '' AND v_alert.product_barcode != 'N/A' THEN
        v_barcode_row := '<tr><td style="padding: 7px 0; color: #64748B;">SKU / Barcode:</td><td style="padding: 7px 0; font-family: monospace; font-weight: 600; color: #1E293B; text-align: right;">' || v_alert.product_barcode || '</td></tr>';
    ELSE
        v_barcode_row := '';
    END IF;

    -- 6. Construct Clean, Mobile-Friendly HTML Email Body
    v_html_body := '<!DOCTYPE html>' ||
      '<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">' ||
      '<title>Low Stock Alert</title></head>' ||
      '<body style="margin: 0; padding: 0; background-color: #F8FAFC; font-family: -apple-system, BlinkMacSystemFont, ''Segoe UI'', Roboto, Helvetica, Arial, sans-serif; color: #1E293B;">' ||
      '<div style="max-width: 580px; margin: 30px auto; background: #FFFFFF; border-radius: 12px; overflow: hidden; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.1); border: 1px solid #E2E8F0;">' ||
        '<div style="background: linear-gradient(135deg, #1E1B4B 0%, #312E81 50%, #4338CA 100%); padding: 24px 30px;">' ||
          '<div style="font-size: 22px; font-weight: 800; color: #FFFFFF; letter-spacing: -0.5px;">ShopFlow</div>' ||
          '<p style="margin: 6px 0 0 0; color: #C7D2FE; font-size: 13px;">Inventory Alert &bull; ' || v_shop_name || '</p>' ||
        '</div>' ||
        '<div style="background: #FEF2F2; border-bottom: 2px solid #FCA5A5; padding: 14px 30px;">' ||
          '<div style="color: #DC2626; font-size: 14px; font-weight: 700;">⚠️ Low Stock Alert: Threshold Reached</div>' ||
        '</div>' ||
        '<div style="padding: 26px 30px;">' ||
          '<p style="margin: 0 0 16px 0; font-size: 14px; line-height: 1.5; color: #334155;">' ||
            'Hello, this is an automated alert for <strong>' || v_shop_name || '</strong>. The following product has reached or fallen below its configured minimum stock threshold:' ||
          '</p>' ||
          '<div style="background: #F8FAFC; border: 1.5px solid #E2E8F0; border-radius: 10px; padding: 18px 20px; margin: 18px 0;">' ||
            '<div style="font-size: 17px; font-weight: 700; color: #0F172A; margin-bottom: 4px;">' || v_alert.product_name || '</div>' ||
            '<div style="display: inline-block; background: #EEF2FF; color: #4338CA; font-size: 11px; font-weight: 600; padding: 2px 8px; border-radius: 99px; margin-bottom: 12px;">' || COALESCE(v_alert.product_category, 'General') || '</div>' ||
            '<table style="width: 100%; border-collapse: collapse; font-size: 13px;">' ||
              v_barcode_row ||
              '<tr><td style="padding: 7px 0; color: #64748B;">Current Stock:</td><td style="padding: 7px 0; font-weight: 800; color: #DC2626; font-size: 16px; text-align: right;">' || v_stock_str || '</td></tr>' ||
              '<tr><td style="padding: 7px 0; color: #64748B;">Minimum Threshold:</td><td style="padding: 7px 0; font-weight: 600; color: #475569; text-align: right;">' || v_min_str || '</td></tr>' ||
              '<tr><td style="padding: 7px 0; color: #64748B;">Alert Date &amp; Time:</td><td style="padding: 7px 0; color: #475569; text-align: right;">' || v_time_str || '</td></tr>' ||
            '</table>' ||
          '</div>' ||
          '<div style="text-align: center; margin: 26px 0 10px 0;">' ||
            '<a href="' || v_config.app_url || '/#/stock" style="display: inline-block; background: #4F46E5; color: #FFFFFF; font-size: 14px; font-weight: 600; text-decoration: none; padding: 11px 26px; border-radius: 8px;">View Stock in ShopFlow &rarr;</a>' ||
          '</div>' ||
          '<p style="text-align: center; font-size: 12px; color: #94A3B8; margin-top: 10px;">' ||
            'Restock incoming inventory directly via <a href="' || v_config.app_url || '/#/new-stock" style="color: #4F46E5;">New Stock Inward</a>.' ||
          '</p>' ||
        '</div>' ||
        '<div style="background: #F1F5F9; border-top: 1px solid #E2E8F0; padding: 14px 30px; text-align: center; font-size: 12px; color: #64748B;">' ||
          'This automated notification was delivered to the registered shop owner of <strong>' || v_shop_name || '</strong>.' ||
        '</div>' ||
      '</div></body></html>';

    -- 7. Dispatch via pg_net Asynchronously (Guarantees zero database blocking)
    BEGIN
        SELECT net.http_post(
            url := 'https://api.resend.com/emails',
            headers := jsonb_build_object(
                'Content-Type', 'application/json',
                'Authorization', 'Bearer ' || v_config.api_key
            ),
            body := jsonb_build_object(
                'from', v_config.sender_email,
                'to', jsonb_build_array(v_recipient),
                'subject', v_subject,
                'html', v_html_body
            )
        ) INTO v_req_id;

        UPDATE public.stock_alerts
        SET email_status = 'sent',
            recipient_email = v_recipient,
            email_sent_at = NOW(),
            last_attempt_at = NOW(),
            email_attempts = email_attempts + 1,
            request_id = v_req_id,
            email_error = NULL
        WHERE id = p_alert_id;

        RETURN jsonb_build_object(
            'success', true,
            'alert_id', p_alert_id,
            'recipient', v_recipient,
            'request_id', v_req_id
        );

    EXCEPTION WHEN OTHERS THEN
        UPDATE public.stock_alerts
        SET email_status = 'failed',
            last_attempt_at = NOW(),
            email_attempts = email_attempts + 1,
            email_error = SUBSTRING(SQLERRM FROM 1 FOR 300)
        WHERE id = p_alert_id;

        RETURN jsonb_build_object('success', false, 'error', SQLERRM);
    END;
END;
$$;

GRANT EXECUTE ON FUNCTION public.dispatch_stock_alert_email(UUID) TO anon, authenticated, service_role;


-- 5. Trigger Function for Automatic Low-Stock Detection and Auto-Resolution
CREATE OR REPLACE FUNCTION public.check_low_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net, extensions
AS $$
DECLARE
    v_threshold          NUMERIC(12,3);
    v_has_active_alert   BOOLEAN;
    v_shop_name          TEXT;
    v_owner_email        TEXT;
    v_new_alert_id       UUID;
BEGIN
    -- Determine configured threshold (defaults to 0 if not set)
    v_threshold := COALESCE(NEW.min_stock, 0);

    -- ─────────────────────────────────────────────────────────────────
    -- CASE 1: Product drops to or below threshold
    -- ─────────────────────────────────────────────────────────────────
    IF NEW.stock_quantity <= v_threshold THEN

        -- Check if an active alert already exists for this product (Duplicate Prevention)
        SELECT EXISTS (
            SELECT 1 FROM public.stock_alerts 
            WHERE product_id = NEW.id AND status = 'active'
        ) INTO v_has_active_alert;

        -- Only trigger if this is a new transition into the low-stock state:
        -- (New product inserted low, or previous stock was above threshold, or no active alert exists)
        IF NOT v_has_active_alert THEN
            -- Resolve registered shop owner email from shops / auth.users
            SELECT 
                s.name,
                COALESCE(NULLIF(TRIM(s.email), ''), NULLIF(TRIM(u.email), ''))
            INTO 
                v_shop_name,
                v_owner_email
            FROM public.shops s
            LEFT JOIN auth.users u ON u.id = s.owner_user_id
            WHERE s.id = NEW.shop_id;

            -- Create transactional alert record
            INSERT INTO public.stock_alerts (
                shop_id,
                product_id,
                status,
                stock_at_alert,
                min_stock_threshold,
                product_name,
                product_category,
                product_unit,
                product_barcode,
                recipient_email,
                email_status
            )
            VALUES (
                NEW.shop_id,
                NEW.id,
                'active',
                NEW.stock_quantity,
                v_threshold,
                NEW.name,
                COALESCE(NEW.category, 'General'),
                COALESCE(NEW.unit, 'pcs'),
                COALESCE(NEW.barcode, 'N/A'),
                COALESCE(v_owner_email, 'MISSING'),
                'pending'
            )
            RETURNING id INTO v_new_alert_id;

            -- Immediately dispatch email notification asynchronously
            PERFORM public.dispatch_stock_alert_email(v_new_alert_id);
        END IF;

    -- ─────────────────────────────────────────────────────────────────
    -- CASE 2: Product replenished above threshold (Auto-Resolution)
    -- ─────────────────────────────────────────────────────────────────
    ELSIF NEW.stock_quantity > v_threshold THEN
        -- Mark any active alerts for this product as resolved
        UPDATE public.stock_alerts
        SET status = 'resolved',
            resolved_at = NOW(),
            resolved_by = 'System Auto-Replenish'
        WHERE product_id = NEW.id AND status = 'active';
    END IF;

    RETURN NEW;
END;
$$;

-- Bind trigger to products table on stock_quantity or min_stock changes
DROP TRIGGER IF EXISTS trigger_check_low_stock ON public.products;
CREATE TRIGGER trigger_check_low_stock
AFTER INSERT OR UPDATE OF stock_quantity, min_stock ON public.products
FOR EACH ROW
EXECUTE FUNCTION public.check_low_stock();


-- 6. RPC: Retry Pending or Failed Alerts
CREATE OR REPLACE FUNCTION public.process_pending_stock_alerts(p_shop_id UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net, extensions
AS $$
DECLARE
    r RECORD;
    v_processed INT := 0;
    v_succeeded INT := 0;
    v_res JSONB;
BEGIN
    FOR r IN 
        SELECT id FROM public.stock_alerts
        WHERE (p_shop_id IS NULL OR shop_id = p_shop_id)
          AND status = 'active'
          AND email_status IN ('pending', 'failed')
          AND email_attempts < 3
        ORDER BY created_at DESC
        LIMIT 20
    LOOP
        v_processed := v_processed + 1;
        v_res := public.dispatch_stock_alert_email(r.id);
        IF (v_res->>'success')::BOOLEAN = true THEN
            v_succeeded := v_succeeded + 1;
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'processed', v_processed,
        'succeeded', v_succeeded
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.process_pending_stock_alerts(UUID) TO anon, authenticated, service_role;


-- 7. RPC: Test Low-Stock Notification On Demand
-- Allows the owner or developer to verify email delivery for any product instantly
CREATE OR REPLACE FUNCTION public.test_low_stock_notification(p_product_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net, extensions
AS $$
DECLARE
    v_prod         RECORD;
    v_shop_name    TEXT;
    v_owner_email  TEXT;
    v_alert_id     UUID;
    v_res          JSONB;
BEGIN
    SELECT p.*, s.name as shop_name, COALESCE(NULLIF(TRIM(s.email), ''), NULLIF(TRIM(u.email), '')) as owner_email
    INTO v_prod
    FROM public.products p
    JOIN public.shops s ON s.id = p.shop_id
    LEFT JOIN auth.users u ON u.id = s.owner_user_id
    WHERE p.id = p_product_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Product not found.');
    END IF;

    -- Create test alert record
    INSERT INTO public.stock_alerts (
        shop_id,
        product_id,
        status,
        stock_at_alert,
        min_stock_threshold,
        product_name,
        product_category,
        product_unit,
        product_barcode,
        recipient_email,
        email_status
    )
    VALUES (
        v_prod.shop_id,
        v_prod.id,
        'active',
        v_prod.stock_quantity,
        COALESCE(v_prod.min_stock, 5),
        v_prod.name,
        COALESCE(v_prod.category, 'General'),
        COALESCE(v_prod.unit, 'pcs'),
        COALESCE(v_prod.barcode, 'N/A'),
        COALESCE(v_prod.owner_email, 'MISSING'),
        'pending'
    )
    RETURNING id INTO v_alert_id;

    -- Dispatch
    v_res := public.dispatch_stock_alert_email(v_alert_id);

    RETURN jsonb_build_object(
        'success', true,
        'test_alert_id', v_alert_id,
        'product', v_prod.name,
        'recipient', v_prod.owner_email,
        'dispatch_result', v_res
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.test_low_stock_notification(UUID) TO anon, authenticated, service_role;


-- 8. RPC: Get Alert Diagnostics for Admin / UI
CREATE OR REPLACE FUNCTION public.get_stock_alert_diagnostics(p_shop_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net, extensions
AS $$
DECLARE
    v_total_alerts    INT;
    v_active_alerts   INT;
    v_resolved_alerts INT;
    v_emails_sent     INT;
    v_emails_failed   INT;
    v_recent_alerts   JSONB;
BEGIN
    SELECT COUNT(*) INTO v_total_alerts FROM public.stock_alerts WHERE shop_id = p_shop_id;
    SELECT COUNT(*) INTO v_active_alerts FROM public.stock_alerts WHERE shop_id = p_shop_id AND status = 'active';
    SELECT COUNT(*) INTO v_resolved_alerts FROM public.stock_alerts WHERE shop_id = p_shop_id AND status = 'resolved';
    SELECT COUNT(*) INTO v_emails_sent FROM public.stock_alerts WHERE shop_id = p_shop_id AND email_status = 'sent';
    SELECT COUNT(*) INTO v_emails_failed FROM public.stock_alerts WHERE shop_id = p_shop_id AND email_status = 'failed';

    SELECT COALESCE(jsonb_agg(row_to_json(t)), '[]'::jsonb) INTO v_recent_alerts
    FROM (
        SELECT 
            id,
            product_name,
            stock_at_alert,
            min_stock_threshold,
            product_unit,
            status,
            recipient_email,
            email_status,
            email_attempts,
            email_error,
            email_sent_at,
            created_at,
            resolved_at
        FROM public.stock_alerts
        WHERE shop_id = p_shop_id
        ORDER BY created_at DESC
        LIMIT 15
    ) t;

    RETURN jsonb_build_object(
        'shop_id', p_shop_id,
        'total_alerts', v_total_alerts,
        'active_alerts', v_active_alerts,
        'resolved_alerts', v_resolved_alerts,
        'emails_sent', v_emails_sent,
        'emails_failed', v_emails_failed,
        'recent_alerts', v_recent_alerts
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_stock_alert_diagnostics(UUID) TO anon, authenticated, service_role;

-- 9. Refresh PostgREST Schema Cache
NOTIFY pgrst, 'reload schema';
