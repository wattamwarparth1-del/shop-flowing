-- ═══════════════════════════════════════════════════════════════
-- ShopFlow — Instant Fix & Recalculation for Udhar / Pending Bills
-- Run this script in Supabase: Dashboard -> SQL Editor -> New Query -> Run
-- ═══════════════════════════════════════════════════════════════

-- 1. FIX PURE UDHAR BILLS (Full Udhar without down payment)
-- Sets pending_amount = grand_total - payments, paid_amount = payments
UPDATE public.bills b
SET 
  paid_amount = COALESCE((SELECT SUM(payment_amount) FROM public.bill_payments WHERE bill_id = b.id), 0.00),
  pending_amount = GREATEST(
    0.00,
    COALESCE(b.grand_total, 0.00) - COALESCE((SELECT SUM(payment_amount) FROM public.bill_payments WHERE bill_id = b.id), 0.00)
  ),
  payment_status = CASE 
    WHEN GREATEST(0.00, COALESCE(b.grand_total, 0.00) - COALESCE((SELECT SUM(payment_amount) FROM public.bill_payments WHERE bill_id = b.id), 0.00)) <= 0.01 THEN 'PAID'
    WHEN COALESCE((SELECT SUM(payment_amount) FROM public.bill_payments WHERE bill_id = b.id), 0.00) > 0 THEN 'PARTIALLY_PAID'
    ELSE 'UNPAID'
  END,
  status = CASE 
    WHEN GREATEST(0.00, COALESCE(b.grand_total, 0.00) - COALESCE((SELECT SUM(payment_amount) FROM public.bill_payments WHERE bill_id = b.id), 0.00)) <= 0.01 THEN 'Completed'
    ELSE 'Partially Paid'
  END
WHERE (b.payment_method ILIKE '%Udhar%' OR b.payment_method ILIKE '%Credit%')
  AND NOT (b.payment_method ILIKE '%Partial%' OR b.payment_method ILIKE '%Rest Udhar%');


-- 2. FIX PARTIAL UDHAR BILLS (e.g., "Partial (₹1000.00 Cash, Rest Udhar)")
-- Extracts the down payment from the payment_method text, adds any subsequent repayments
UPDATE public.bills b
SET 
  paid_amount = LEAST(
    COALESCE(b.grand_total, 0.00),
    COALESCE(
      NULLIF(SUBSTRING(b.payment_method FROM '[0-9]+\.?[0-9]*'), '')::NUMERIC,
      0.00
    ) + COALESCE((SELECT SUM(payment_amount) FROM public.bill_payments WHERE bill_id = b.id), 0.00)
  ),
  pending_amount = GREATEST(
    0.00,
    COALESCE(b.grand_total, 0.00) - (
      COALESCE(
        NULLIF(SUBSTRING(b.payment_method FROM '[0-9]+\.?[0-9]*'), '')::NUMERIC,
        0.00
      ) + COALESCE((SELECT SUM(payment_amount) FROM public.bill_payments WHERE bill_id = b.id), 0.00)
    )
  ),
  payment_status = CASE 
    WHEN GREATEST(
      0.00,
      COALESCE(b.grand_total, 0.00) - (
        COALESCE(NULLIF(SUBSTRING(b.payment_method FROM '[0-9]+\.?[0-9]*'), '')::NUMERIC, 0.00) + 
        COALESCE((SELECT SUM(payment_amount) FROM public.bill_payments WHERE bill_id = b.id), 0.00)
      )
    ) <= 0.01 THEN 'PAID'
    ELSE 'PARTIALLY_PAID'
  END,
  status = CASE 
    WHEN GREATEST(
      0.00,
      COALESCE(b.grand_total, 0.00) - (
        COALESCE(NULLIF(SUBSTRING(b.payment_method FROM '[0-9]+\.?[0-9]*'), '')::NUMERIC, 0.00) + 
        COALESCE((SELECT SUM(payment_amount) FROM public.bill_payments WHERE bill_id = b.id), 0.00)
      )
    ) <= 0.01 THEN 'Completed'
    ELSE 'Partially Paid'
  END
WHERE (b.payment_method ILIKE '%Partial%' AND b.payment_method ILIKE '%Udhar%')
   OR (b.payment_method ILIKE '%Rest Udhar%');


-- 3. RECORD INITIAL DOWN-PAYMENTS IN bill_payments (if not already recorded)
INSERT INTO public.bill_payments (
  shop_id,
  bill_id,
  customer_id,
  receipt_number,
  payment_amount,
  payment_method,
  notes,
  previous_paid,
  new_paid,
  remaining_due,
  created_by,
  created_at
)
SELECT 
  b.shop_id,
  b.id,
  b.customer_id,
  'RCP-DOWN-' || TO_CHAR(b.created_at, 'YYYYMMDD') || '-' || SUBSTRING(b.id::TEXT, 1, 6),
  b.paid_amount,
  'Cash',
  'Down payment collected at bill creation',
  0.00,
  b.paid_amount,
  b.pending_amount,
  COALESCE(b.staff_name, 'Staff'),
  b.created_at
FROM public.bills b
WHERE ((b.payment_method ILIKE '%Partial%' AND b.payment_method ILIKE '%Udhar%') OR b.payment_method ILIKE '%Rest Udhar%')
  AND b.paid_amount > 0
  AND NOT EXISTS (
    SELECT 1 FROM public.bill_payments bp WHERE bp.bill_id = b.id
  );


-- 4. UPDATE SAVE_BILL RPC TO FULLY SUPPORT UDHAR PARAMETERS DIRECTLY
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
  p_items           JSONB,
  p_paid_amount     NUMERIC DEFAULT NULL,
  p_pending_amount  NUMERIC DEFAULT NULL,
  p_payment_status  TEXT DEFAULT NULL,
  p_due_date        TIMESTAMPTZ DEFAULT NULL
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
  v_paid           NUMERIC(12,2);
  v_pending        NUMERIC(12,2);
  v_status         TEXT;
  v_bill_status    TEXT;
BEGIN
  -- Generate Sequential Bill Number (e.g. INV-000001)
  SELECT COALESCE(bill_prefix, 'INV'), COALESCE(next_bill_number, 1)
  INTO v_prefix, v_next_num
  FROM public.shops WHERE id = p_shop_id FOR UPDATE;

  v_bill_number := v_prefix || '-' || LPAD(v_next_num::TEXT, 6, '0');

  UPDATE public.shops SET next_bill_number = v_next_num + 1 WHERE id = p_shop_id;

  -- Resolve Udhar balances if not explicitly passed
  IF p_paid_amount IS NOT NULL THEN
    v_paid := p_paid_amount;
  ELSE
    IF p_payment_method ILIKE '%Udhar%' OR p_payment_method ILIKE '%Credit%' THEN
      v_paid := 0.00;
    ELSE
      v_paid := p_grand_total;
    END IF;
  END IF;

  IF p_pending_amount IS NOT NULL THEN
    v_pending := p_pending_amount;
  ELSE
    v_pending := GREATEST(0.00, p_grand_total - v_paid);
  END IF;

  IF p_payment_status IS NOT NULL THEN
    v_status := p_payment_status;
  ELSE
    IF v_pending <= 0.01 THEN
      v_status := 'PAID';
    ELSIF v_paid > 0 THEN
      v_status := 'PARTIALLY_PAID';
    ELSE
      v_status := 'UNPAID';
    END IF;
  END IF;

  v_bill_status := CASE WHEN v_status = 'PAID' THEN 'Completed' ELSE 'Partially Paid' END;

  -- Create Bill Record with Udhar columns
  INSERT INTO public.bills (
    shop_id, bill_number, customer_id, customer_name, customer_mobile,
    staff_id, staff_name, pos_id, subtotal, discount_pct, discount_amount,
    gst_amount, grand_total, payment_method,
    paid_amount, pending_amount, payment_status, due_date, status
  )
  VALUES (
    p_shop_id, v_bill_number, p_customer_id, COALESCE(p_customer_name, 'Walk-in Customer'),
    p_customer_mobile, p_staff_id, p_staff_name, p_pos_id,
    p_subtotal, p_discount_pct, p_discount_amount, p_gst_amount, p_grand_total, p_payment_method,
    v_paid, v_pending, v_status, p_due_date, v_bill_status
  )
  RETURNING id INTO v_bill_id;

  -- Process Items and deduct inventory
  FOR item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_product_id := (item->>'product_id')::UUID;
    v_prod_name  := item->>'name';
    v_qty        := (item->>'quantity')::NUMERIC;
    v_unit_price := (item->>'price')::NUMERIC;
    v_gst_pct    := COALESCE((item->>'gst_pct')::NUMERIC, 0);
    v_gst_amt    := COALESCE((item->>'gst_amount')::NUMERIC, 0);
    v_item_tot   := (item->>'total')::NUMERIC;

    INSERT INTO public.bill_items (
      bill_id, shop_id, product_id, product_name, quantity, unit_price, gst_percentage, gst_amount, total_amount
    )
    VALUES (
      v_bill_id, p_shop_id, v_product_id, v_prod_name, v_qty, v_unit_price, v_gst_pct, v_gst_amt, v_item_tot
    );

    IF v_product_id IS NOT NULL THEN
      SELECT stock_quantity INTO v_cur_stock FROM public.products WHERE id = v_product_id FOR UPDATE;
      IF FOUND THEN
        v_new_stock := v_cur_stock - v_qty;
        UPDATE public.products SET stock_quantity = v_new_stock, updated_at = NOW() WHERE id = v_product_id;

        INSERT INTO public.stock_movements (
          shop_id, product_id, change_type, quantity, previous_stock, new_stock, reference_id, created_by
        )
        VALUES (
          p_shop_id, v_product_id, 'sale', -v_qty, v_cur_stock, v_new_stock, v_bill_number, COALESCE(p_staff_name, 'Staff')
        );
      END IF;
    END IF;
  END LOOP;

  -- Update Customer aggregate stats
  IF p_customer_id IS NOT NULL THEN
    UPDATE public.customers
    SET
      total_bills = COALESCE(total_bills, 0) + 1,
      total_spent = COALESCE(total_spent, 0) + p_grand_total,
      last_visit  = NOW(),
      updated_at  = NOW()
    WHERE id = p_customer_id;
  END IF;

  RETURN json_build_object(
    'success', true,
    'bill_id', v_bill_id,
    'bill_number', v_bill_number,
    'paid_amount', v_paid,
    'pending_amount', v_pending,
    'payment_status', v_status
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.save_bill TO anon, authenticated;

-- Verification check query to see updated rows:
SELECT 
  bill_number,
  customer_name,
  payment_method,
  grand_total,
  paid_amount,
  pending_amount,
  payment_status,
  status
FROM public.bills
WHERE payment_method ILIKE '%Udhar%' OR payment_method ILIKE '%Credit%'
ORDER BY created_at DESC;
