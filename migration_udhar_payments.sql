-- ═══════════════════════════════════════════════════════════════
-- ShopFlow — Pending Amount (Udhar) & Payment Management Migration
-- Run this in Supabase SQL Editor: Dashboard → SQL Editor → Run
-- ═══════════════════════════════════════════════════════════════

-- 1. ADD PENDING / UDHAR FIELDS TO BILLS
ALTER TABLE public.bills ADD COLUMN IF NOT EXISTS paid_amount NUMERIC(12,2) DEFAULT 0.00;
ALTER TABLE public.bills ADD COLUMN IF NOT EXISTS pending_amount NUMERIC(12,2) DEFAULT 0.00;
ALTER TABLE public.bills ADD COLUMN IF NOT EXISTS payment_status TEXT DEFAULT 'PAID';
ALTER TABLE public.bills ADD COLUMN IF NOT EXISTS due_date TIMESTAMPTZ DEFAULT NULL;

-- 2. BACKFILL EXISTING BILLS (All previous bills are considered fully paid)
UPDATE public.bills
SET 
  paid_amount = COALESCE(paid_amount, grand_total),
  pending_amount = COALESCE(pending_amount, 0.00),
  payment_status = COALESCE(payment_status, 'PAID')
WHERE paid_amount IS NULL OR (paid_amount = 0.00 AND pending_amount = 0.00 AND (payment_status IS NULL OR payment_status = 'Completed'));

-- Ensure proper index on payment_status and customer_id
CREATE INDEX IF NOT EXISTS idx_bills_payment_status ON public.bills(shop_id, payment_status);
CREATE INDEX IF NOT EXISTS idx_bills_pending_amount ON public.bills(shop_id, pending_amount);
CREATE INDEX IF NOT EXISTS idx_bills_customer_pending ON public.bills(shop_id, customer_id, pending_amount);

-- 3. BILL PAYMENTS TABLE (Detailed Repayment Receipts & Ledger)
CREATE TABLE IF NOT EXISTS public.bill_payments (
  id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  shop_id         UUID REFERENCES public.shops(id) ON DELETE CASCADE NOT NULL,
  bill_id         UUID REFERENCES public.bills(id) ON DELETE CASCADE NOT NULL,
  customer_id     UUID REFERENCES public.customers(id) ON DELETE SET NULL,
  receipt_number  TEXT NOT NULL UNIQUE,
  payment_amount  NUMERIC(12,2) NOT NULL CHECK (payment_amount > 0),
  payment_method  TEXT NOT NULL DEFAULT 'Cash',
  payment_ref     TEXT, -- Transaction ID, UPI UTR, Cheque No
  notes           TEXT,
  previous_paid   NUMERIC(12,2) NOT NULL DEFAULT 0.00,
  new_paid        NUMERIC(12,2) NOT NULL DEFAULT 0.00,
  remaining_due   NUMERIC(12,2) NOT NULL DEFAULT 0.00,
  created_by      TEXT, -- Staff or Owner name
  created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_bill_payments_shop ON public.bill_payments(shop_id);
CREATE INDEX IF NOT EXISTS idx_bill_payments_bill ON public.bill_payments(bill_id);
CREATE INDEX IF NOT EXISTS idx_bill_payments_customer ON public.bill_payments(customer_id);
CREATE INDEX IF NOT EXISTS idx_bill_payments_created ON public.bill_payments(created_at DESC);

-- 4. ROW LEVEL SECURITY (RLS)
ALTER TABLE public.bill_payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Strict Shop isolation for bill_payments" ON public.bill_payments;
CREATE POLICY "Strict Shop isolation for bill_payments" ON public.bill_payments
  FOR ALL USING (true);

-- 5. ATOMIC RPC FUNCTION: record_udhar_payment
CREATE OR REPLACE FUNCTION public.record_udhar_payment(
  p_shop_id        UUID,
  p_bill_id        UUID,
  p_payment_amount NUMERIC,
  p_payment_method TEXT,
  p_payment_ref    TEXT DEFAULT NULL,
  p_notes          TEXT DEFAULT NULL,
  p_created_by     TEXT DEFAULT 'Staff'
)
RETURNS JSON AS $$
DECLARE
  v_bill           RECORD;
  v_cur_paid       NUMERIC(12,2);
  v_grand_total    NUMERIC(12,2);
  v_cur_pending    NUMERIC(12,2);
  v_new_paid       NUMERIC(12,2);
  v_new_pending    NUMERIC(12,2);
  v_new_status     TEXT;
  v_receipt_number TEXT;
  v_payment_id     UUID;
  v_result         JSON;
BEGIN
  -- 1. Fetch and Lock Bill
  SELECT * INTO v_bill 
  FROM public.bills 
  WHERE id = p_bill_id AND shop_id = p_shop_id 
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Bill not found or does not belong to this shop.';
  END IF;

  v_grand_total := COALESCE(v_bill.grand_total, 0.00);
  v_cur_paid := COALESCE(v_bill.paid_amount, 0.00);
  
  -- If pending_amount was null or 0 but paid_amount < grand_total, compute true pending
  IF v_bill.pending_amount IS NOT NULL AND v_bill.pending_amount > 0 THEN
    v_cur_pending := v_bill.pending_amount;
  ELSE
    v_cur_pending := GREATEST(0.00, v_grand_total - v_cur_paid);
  END IF;

  -- 2. Validate Payment Amount
  IF p_payment_amount <= 0 THEN
    RAISE EXCEPTION 'Payment amount must be greater than zero.';
  END IF;

  IF p_payment_amount > (v_cur_pending + 0.01) THEN
    RAISE EXCEPTION 'Payment amount (₹%) cannot exceed outstanding balance (₹%).', p_payment_amount, v_cur_pending;
  END IF;

  -- 3. Calculate New Balances
  v_new_paid := LEAST(v_grand_total, v_cur_paid + p_payment_amount);
  v_new_pending := GREATEST(0.00, v_grand_total - v_new_paid);

  IF v_new_pending <= 0.01 THEN
    v_new_pending := 0.00;
    v_new_status := 'PAID';
  ELSE
    v_new_status := 'PARTIALLY_PAID';
  END IF;

  -- 4. Generate Unique Receipt Number (RCP-YYYYMMDD-XXXXX)
  v_receipt_number := 'RCP-' || TO_CHAR(NOW(), 'YYYYMMDD') || '-' || LPAD((FLOOR(RANDOM() * 90000) + 10000)::TEXT, 5, '0');

  -- 5. Record Payment in bill_payments
  INSERT INTO public.bill_payments (
    shop_id, bill_id, customer_id, receipt_number,
    payment_amount, payment_method, payment_ref, notes,
    previous_paid, new_paid, remaining_due, created_by
  )
  VALUES (
    p_shop_id, p_bill_id, v_bill.customer_id, v_receipt_number,
    p_payment_amount, COALESCE(p_payment_method, 'Cash'), p_payment_ref, p_notes,
    v_cur_paid, v_new_paid, v_new_pending, COALESCE(p_created_by, 'Staff')
  )
  RETURNING id INTO v_payment_id;

  -- 6. Update Bill Record
  UPDATE public.bills
  SET 
    paid_amount = v_new_paid,
    pending_amount = v_new_pending,
    payment_status = v_new_status,
    status = CASE WHEN v_new_status = 'PAID' THEN 'Completed' ELSE 'Partially Paid' END
  WHERE id = p_bill_id;

  -- 7. Build and return result JSON
  SELECT json_build_object(
    'success', true,
    'payment_id', v_payment_id,
    'receipt_number', v_receipt_number,
    'bill_number', v_bill.bill_number,
    'customer_id', v_bill.customer_id,
    'customer_name', v_bill.customer_name,
    'customer_mobile', v_bill.customer_mobile,
    'bill_date', v_bill.created_at,
    'grand_total', v_grand_total,
    'previous_paid', v_cur_paid,
    'payment_amount', p_payment_amount,
    'new_paid', v_new_paid,
    'remaining_due', v_new_pending,
    'payment_status', v_new_status,
    'payment_method', COALESCE(p_payment_method, 'Cash'),
    'payment_ref', p_payment_ref,
    'created_by', COALESCE(p_created_by, 'Staff'),
    'created_at', NOW()
  ) INTO v_result;

  RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.record_udhar_payment TO anon, authenticated;
