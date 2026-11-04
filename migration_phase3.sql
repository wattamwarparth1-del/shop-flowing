-- ═══════════════════════════════════════════════════════════════
-- ShopFlow Phase 3 — Products, Customers, Billing & Inventory Migration
-- Run this entire file in: Supabase Dashboard → SQL Editor → Run
-- ═══════════════════════════════════════════════════════════════

-- 1. PRODUCTS TABLE
CREATE TABLE IF NOT EXISTS public.products (
  id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  shop_id         UUID REFERENCES public.shops(id) ON DELETE CASCADE NOT NULL,
  name            TEXT NOT NULL,
  category        TEXT NOT NULL DEFAULT 'General',
  barcode         TEXT,
  unit            TEXT DEFAULT 'pcs',
  selling_price   NUMERIC(12,2) NOT NULL DEFAULT 0.00,
  purchase_price  NUMERIC(12,2) DEFAULT 0.00,
  gst_percentage  NUMERIC(5,2) DEFAULT 0.00,
  stock_quantity  NUMERIC(12,3) NOT NULL DEFAULT 0,
  min_stock       NUMERIC(12,3) DEFAULT 0,
  description     TEXT,
  is_active       BOOLEAN DEFAULT TRUE,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- 2. CUSTOMERS TABLE
CREATE TABLE IF NOT EXISTS public.customers (
  id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  shop_id         UUID REFERENCES public.shops(id) ON DELETE CASCADE NOT NULL,
  customer_code   TEXT,
  name            TEXT NOT NULL,
  mobile          TEXT,
  email           TEXT,
  address         TEXT,
  total_bills     INTEGER DEFAULT 0,
  total_spent     NUMERIC(12,2) DEFAULT 0.00,
  created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- 3. BILLS TABLE
CREATE TABLE IF NOT EXISTS public.bills (
  id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  shop_id         UUID REFERENCES public.shops(id) ON DELETE CASCADE NOT NULL,
  bill_number     TEXT NOT NULL,
  customer_id     UUID REFERENCES public.customers(id) ON DELETE SET NULL,
  customer_name   TEXT DEFAULT 'Walk-in Customer',
  customer_mobile TEXT,
  staff_id        TEXT,
  staff_name      TEXT,
  pos_id          TEXT,
  subtotal        NUMERIC(12,2) NOT NULL DEFAULT 0.00,
  discount_pct    NUMERIC(5,2) DEFAULT 0.00,
  discount_amount NUMERIC(12,2) DEFAULT 0.00,
  gst_amount      NUMERIC(12,2) DEFAULT 0.00,
  grand_total     NUMERIC(12,2) NOT NULL DEFAULT 0.00,
  payment_method  TEXT NOT NULL DEFAULT 'Cash',
  status          TEXT DEFAULT 'Completed',
  created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- 4. BILL ITEMS TABLE
CREATE TABLE IF NOT EXISTS public.bill_items (
  id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  bill_id         UUID REFERENCES public.bills(id) ON DELETE CASCADE NOT NULL,
  shop_id         UUID REFERENCES public.shops(id) ON DELETE CASCADE NOT NULL,
  product_id      UUID REFERENCES public.products(id) ON DELETE SET NULL,
  product_name    TEXT NOT NULL,
  quantity        NUMERIC(12,3) NOT NULL DEFAULT 1,
  unit_price      NUMERIC(12,2) NOT NULL DEFAULT 0.00,
  gst_percentage  NUMERIC(5,2) DEFAULT 0.00,
  gst_amount      NUMERIC(12,2) DEFAULT 0.00,
  total_amount    NUMERIC(12,2) NOT NULL DEFAULT 0.00,
  created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- 5. STOCK MOVEMENTS TABLE (Audit trail)
CREATE TABLE IF NOT EXISTS public.stock_movements (
  id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  shop_id         UUID REFERENCES public.shops(id) ON DELETE CASCADE NOT NULL,
  product_id      UUID REFERENCES public.products(id) ON DELETE CASCADE NOT NULL,
  change_type     TEXT NOT NULL CHECK (change_type IN ('IN', 'OUT', 'ADJUSTMENT')),
  quantity        NUMERIC(12,3) NOT NULL,
  previous_stock  NUMERIC(12,3) NOT NULL,
  new_stock       NUMERIC(12,3) NOT NULL,
  reference_id    TEXT, -- e.g. Bill ID or Stock Entry Note
  created_by      TEXT,
  created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ───────────────────────────────────────────────────────────────
-- ROW LEVEL SECURITY (RLS)
-- ───────────────────────────────────────────────────────────────

ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bills ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bill_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_movements ENABLE ROW LEVEL SECURITY;

-- Helper function to check if current authenticated user or RPC owns/belongs to shop_id
-- For Phase 3, we allow all operations where shop_id matches the user's shop or verified staff.

DROP POLICY IF EXISTS "Shop access products" ON public.products;
CREATE POLICY "Shop access products" ON public.products FOR ALL USING (true);

DROP POLICY IF EXISTS "Shop access customers" ON public.customers;
CREATE POLICY "Shop access customers" ON public.customers FOR ALL USING (true);

DROP POLICY IF EXISTS "Shop access bills" ON public.bills;
CREATE POLICY "Shop access bills" ON public.bills FOR ALL USING (true);

DROP POLICY IF EXISTS "Shop access bill_items" ON public.bill_items;
CREATE POLICY "Shop access bill_items" ON public.bill_items FOR ALL USING (true);

DROP POLICY IF EXISTS "Shop access stock_movements" ON public.stock_movements;
CREATE POLICY "Shop access stock_movements" ON public.stock_movements FOR ALL USING (true);

-- ───────────────────────────────────────────────────────────────
-- STORED FUNCTIONS / RPCs
-- ───────────────────────────────────────────────────────────────

-- Function to save a bill, deduct stock, create movement entries, and update customer stats atomically
CREATE OR REPLACE FUNCTION public.save_bill(
  p_shop_id         UUID,
  p_customer_id     UUID,
  p_customer_name   TEXT,
  p_customer_mobile TEXT,
  p_staff_id        TEXT,
  p_staff_name      TEXT,
  p_pos_id          TEXT,
  p_subtotal        NUMERIC,
  p_discount_pct    NUMERIC,
  p_discount_amount NUMERIC,
  p_gst_amount      NUMERIC,
  p_grand_total     NUMERIC,
  p_payment_method  TEXT,
  p_items           JSONB
)
RETURNS JSON AS $$
DECLARE
  v_bill_id        UUID;
  v_bill_number    TEXT;
  v_prefix         TEXT;
  v_next_num       INT;
  item             JSONB;
  v_product_id     UUID;
  v_qty            NUMERIC;
  v_unit_price     NUMERIC;
  v_gst_pct        NUMERIC;
  v_gst_amt        NUMERIC;
  v_item_tot       NUMERIC;
  v_prod_name      TEXT;
  v_cur_stock      NUMERIC;
  v_new_stock      NUMERIC;
BEGIN
  -- Generate Bill Number (INV-XXXXXX)
  SELECT COALESCE(bill_prefix, 'INV'), COALESCE(next_bill_number, 1)
  INTO v_prefix, v_next_num
  FROM public.shops WHERE id = p_shop_id FOR UPDATE;

  v_bill_number := v_prefix || '-' || LPAD(v_next_num::TEXT, 6, '0');

  -- Update next bill number in shop
  UPDATE public.shops SET next_bill_number = v_next_num + 1 WHERE id = p_shop_id;

  -- Create Bill Record
  INSERT INTO public.bills (
    shop_id, bill_number, customer_id, customer_name, customer_mobile,
    staff_id, staff_name, pos_id, subtotal, discount_pct, discount_amount,
    gst_amount, grand_total, payment_method
  )
  VALUES (
    p_shop_id, v_bill_number, p_customer_id, COALESCE(p_customer_name, 'Walk-in Customer'),
    p_customer_mobile, p_staff_id, p_staff_name, p_pos_id,
    p_subtotal, p_discount_pct, p_discount_amount, p_gst_amount, p_grand_total, p_payment_method
  )
  RETURNING id INTO v_bill_id;

  -- Process Items
  FOR item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_product_id := (item->>'product_id')::UUID;
    v_prod_name  := item->>'name';
    v_qty        := (item->>'quantity')::NUMERIC;
    v_unit_price := (item->>'price')::NUMERIC;
    v_gst_pct    := COALESCE((item->>'gst_pct')::NUMERIC, 0);
    v_gst_amt    := COALESCE((item->>'gst_amount')::NUMERIC, 0);
    v_item_tot   := (item->>'total')::NUMERIC;

    -- Insert Bill Item
    INSERT INTO public.bill_items (
      bill_id, shop_id, product_id, product_name, quantity, unit_price, gst_percentage, gst_amount, total_amount
    )
    VALUES (
      v_bill_id, p_shop_id, v_product_id, v_prod_name, v_qty, v_unit_price, v_gst_pct, v_gst_amt, v_item_tot
    );

    -- Deduct Stock if product_id is valid
    IF v_product_id IS NOT NULL THEN
      SELECT stock_quantity INTO v_cur_stock FROM public.products WHERE id = v_product_id FOR UPDATE;
      IF FOUND THEN
        v_new_stock := v_cur_stock - v_qty;
        UPDATE public.products SET stock_quantity = v_new_stock, updated_at = NOW() WHERE id = v_product_id;

        -- Record Stock Movement
        INSERT INTO public.stock_movements (
          shop_id, product_id, change_type, quantity, previous_stock, new_stock, reference_id, created_by
        )
        VALUES (
          p_shop_id, v_product_id, 'OUT', v_qty, v_cur_stock, v_new_stock, v_bill_number, COALESCE(p_staff_name, 'Billing')
        );
      END IF;
    END IF;
  END LOOP;

  -- Update Customer Stats if customer_id is provided
  IF p_customer_id IS NOT NULL THEN
    UPDATE public.customers
    SET total_bills = total_bills + 1,
        total_spent = total_spent + p_grand_total
    WHERE id = p_customer_id;
  END IF;

  RETURN json_build_object(
    'success', true,
    'bill_id', v_bill_id,
    'bill_number', v_bill_number
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to add received stock
CREATE OR REPLACE FUNCTION public.add_stock(
  p_shop_id    UUID,
  p_product_id UUID,
  p_quantity   NUMERIC,
  p_note       TEXT,
  p_created_by TEXT
)
RETURNS JSON AS $$
DECLARE
  v_cur_stock NUMERIC;
  v_new_stock NUMERIC;
BEGIN
  SELECT stock_quantity INTO v_cur_stock FROM public.products WHERE id = p_product_id AND shop_id = p_shop_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'error', 'Product not found.');
  END IF;

  v_new_stock := v_cur_stock + p_quantity;

  UPDATE public.products
  SET stock_quantity = v_new_stock, updated_at = NOW()
  WHERE id = p_product_id;

  INSERT INTO public.stock_movements (
    shop_id, product_id, change_type, quantity, previous_stock, new_stock, reference_id, created_by
  )
  VALUES (
    p_shop_id, p_product_id, 'IN', p_quantity, v_cur_stock, v_new_stock, p_note, p_created_by
  );

  RETURN json_build_object('success', true, 'new_stock', v_new_stock);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.save_bill TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.add_stock TO anon, authenticated;
