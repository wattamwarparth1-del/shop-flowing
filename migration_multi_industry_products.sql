-- ═══════════════════════════════════════════════════════════════
-- ShopFlow Migration — Multi-Industry Product System & Schema Fix
-- Safe, non-breaking, idempotent migration for all shop types
-- Run in: Supabase Dashboard → SQL Editor → Run
-- ═══════════════════════════════════════════════════════════════

-- 1. Ensure purchase_price column exists on products
ALTER TABLE public.products 
ADD COLUMN IF NOT EXISTS purchase_price NUMERIC(12,2) DEFAULT 0.00;

-- 2. Add cost_price column globally so queries using cost_price succeed
ALTER TABLE public.products 
ADD COLUMN IF NOT EXISTS cost_price NUMERIC(12,2) DEFAULT 0.00;

-- 3. Sync existing cost_price with purchase_price
UPDATE public.products 
SET cost_price = purchase_price 
WHERE (cost_price IS NULL OR cost_price = 0) AND purchase_price > 0;

UPDATE public.products 
SET purchase_price = cost_price 
WHERE (purchase_price IS NULL OR purchase_price = 0) AND cost_price > 0;

-- 4. Add common retail product columns
ALTER TABLE public.products 
ADD COLUMN IF NOT EXISTS mrp NUMERIC(12,2) DEFAULT NULL;

ALTER TABLE public.products 
ADD COLUMN IF NOT EXISTS brand TEXT DEFAULT NULL;

ALTER TABLE public.products 
ADD COLUMN IF NOT EXISTS hsn_code TEXT DEFAULT NULL;

-- 5. Add structured JSONB attributes column for industry-specific specifications
-- (Paint: shade_code, finish, container_size, base_type; Jewellery: purity, gross_weight, net_weight, making_charges; etc.)
ALTER TABLE public.products 
ADD COLUMN IF NOT EXISTS attributes JSONB DEFAULT '{}'::jsonb;

-- 6. Add GIN index on attributes for high-performance JSON querying
CREATE INDEX IF NOT EXISTS idx_products_attributes_gin ON public.products USING GIN (attributes);

-- 7. Add index on brand for fast filtering
CREATE INDEX IF NOT EXISTS idx_products_brand ON public.products(shop_id, brand);

-- 8. Keep cost_price and purchase_price synchronized automatically
CREATE OR REPLACE FUNCTION public.sync_product_prices()
RETURNS TRIGGER AS $$
BEGIN
  -- Reconcile cost_price and purchase_price
  IF NEW.cost_price IS NOT NULL AND (NEW.purchase_price IS NULL OR NEW.purchase_price = 0) THEN
    NEW.purchase_price := NEW.cost_price;
  ELSIF NEW.purchase_price IS NOT NULL AND (NEW.cost_price IS NULL OR NEW.cost_price = 0) THEN
    NEW.cost_price := NEW.purchase_price;
  END IF;

  -- Ensure attributes is never null
  IF NEW.attributes IS NULL THEN
    NEW.attributes := '{}'::jsonb;
  END IF;

  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_product_prices ON public.products;
CREATE TRIGGER trg_sync_product_prices
BEFORE INSERT OR UPDATE ON public.products
FOR EACH ROW
EXECUTE FUNCTION public.sync_product_prices();

-- 9. Refresh PostgREST schema cache so columns are immediately visible
NOTIFY pgrst, 'reload schema';
