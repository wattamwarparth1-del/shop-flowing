-- ═══════════════════════════════════════════════════════════════
-- ShopFlow — Logo and Custom QR Image Assets Migration
-- Run this in Supabase Dashboard → SQL Editor → Run
-- ═══════════════════════════════════════════════════════════════

ALTER TABLE public.shops 
  ADD COLUMN IF NOT EXISTS logo_url TEXT,
  ADD COLUMN IF NOT EXISTS qr_image_url TEXT;

-- Create storage bucket for receipt assets if storage schema is available
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'storage' AND table_name = 'buckets') THEN
    INSERT INTO storage.buckets (id, name, public)
    VALUES ('receipt-assets', 'receipt-assets', true)
    ON CONFLICT (id) DO NOTHING;
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    NULL; -- Ignore if storage extension is not enabled or restricted
END $$;
