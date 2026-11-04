-- ═══════════════════════════════════════════════════════════════
-- ShopFlow Migration — Stock Filler Role & Low Stock Alert System
-- Run this in Supabase Dashboard → SQL Editor → Run
-- ═══════════════════════════════════════════════════════════════

-- 1. Create Stock Alerts Table
CREATE TABLE IF NOT EXISTS public.stock_alerts (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    shop_id UUID REFERENCES public.shops(id) ON DELETE CASCADE NOT NULL,
    product_id UUID REFERENCES public.products(id) ON DELETE CASCADE NOT NULL,
    status TEXT NOT NULL DEFAULT 'active', -- 'active' or 'resolved'
    created_at TIMESTAMPTZ DEFAULT NOW(),
    resolved_at TIMESTAMPTZ,
    resolved_by TEXT
);

-- RLS for stock alerts
ALTER TABLE public.stock_alerts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Shop access stock_alerts" ON public.stock_alerts;
CREATE POLICY "Shop access stock_alerts" ON public.stock_alerts FOR ALL USING (true);


-- 2. Trigger for Automatic Low-Stock Detection
CREATE OR REPLACE FUNCTION public.check_low_stock()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- If inserted with low stock
        IF NEW.stock_quantity <= COALESCE(NEW.min_stock, 5) THEN
            INSERT INTO public.stock_alerts (shop_id, product_id, status)
            VALUES (NEW.shop_id, NEW.id, 'active');
        END IF;
    ELSIF TG_OP = 'UPDATE' THEN
        -- If stock dropped below minimum
        IF NEW.stock_quantity <= COALESCE(NEW.min_stock, 5) AND OLD.stock_quantity > COALESCE(OLD.min_stock, 5) THEN
            IF NOT EXISTS (SELECT 1 FROM public.stock_alerts WHERE product_id = NEW.id AND status = 'active') THEN
                INSERT INTO public.stock_alerts (shop_id, product_id, status)
                VALUES (NEW.shop_id, NEW.id, 'active');
            END IF;
        -- If stock was replenished above minimum
        ELSIF NEW.stock_quantity > COALESCE(NEW.min_stock, 5) AND OLD.stock_quantity <= COALESCE(OLD.min_stock, 5) THEN
            UPDATE public.stock_alerts 
            SET status = 'resolved', resolved_at = NOW(), resolved_by = 'System Auto-Replenish' 
            WHERE product_id = NEW.id AND status = 'active';
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_check_low_stock ON public.products;
CREATE TRIGGER trigger_check_low_stock
AFTER INSERT OR UPDATE OF stock_quantity ON public.products
FOR EACH ROW
EXECUTE FUNCTION public.check_low_stock();


-- 3. Enforce Permissions at Backend / Database Level
-- Prevent staff/cashier/stock_filler (who operate via anon key) from deleting critical records.
-- Only the shop owner (who uses auth.uid()) can perform DELETEs.
CREATE OR REPLACE FUNCTION public.prevent_anon_deletes()
RETURNS TRIGGER AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Action not permitted: You do not have permission to delete records.';
    END IF;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS block_product_delete ON public.products;
CREATE TRIGGER block_product_delete BEFORE DELETE ON public.products FOR EACH ROW EXECUTE FUNCTION public.prevent_anon_deletes();

DROP TRIGGER IF EXISTS block_bills_delete ON public.bills;
CREATE TRIGGER block_bills_delete BEFORE DELETE ON public.bills FOR EACH ROW EXECUTE FUNCTION public.prevent_anon_deletes();

DROP TRIGGER IF EXISTS block_stock_movements_delete ON public.stock_movements;
CREATE TRIGGER block_stock_movements_delete BEFORE DELETE ON public.stock_movements FOR EACH ROW EXECUTE FUNCTION public.prevent_anon_deletes();

-- 4. RPC for Stock Filler to manually mark alert as resolved (optional, but good for UI)
CREATE OR REPLACE FUNCTION public.resolve_stock_alert(
  p_alert_id UUID,
  p_staff_name TEXT
)
RETURNS JSON AS $$
BEGIN
  UPDATE public.stock_alerts
  SET status = 'resolved',
      resolved_at = NOW(),
      resolved_by = p_staff_name
  WHERE id = p_alert_id AND status = 'active';

  RETURN json_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.resolve_stock_alert TO anon, authenticated;
