-- =====================================================================
-- ICT371 Advanced Database | Question 2: University Fee Payments
-- Name: ________________ | Student number: ____________ | PostgreSQL 16 (PL/pgSQL)
-- Credit balances are not allowed: a payment can never exceed the balance.
-- =====================================================================

DROP SCHEMA IF EXISTS q2 CASCADE;
CREATE SCHEMA q2;
SET search_path TO q2;

-- ---------------------------------------------------------------------
-- (a) Database and seed data [6 marks]
-- ---------------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL,
    fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on    DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE payment_audit (
    audit_id   SERIAL PRIMARY KEY,
    payment_id INTEGER NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    logged_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INTEGER NOT NULL DEFAULT 0 CHECK (payment_count >= 0),
    total_amount    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0)
);

INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('202001698', 'Mapalo Chileshe', 15000.00),
    ('202001700', 'Mwila Banda',   12000.00),
    ('202001701', 'Natasha Phiri',  9000.00);   -- will have no payments
-- Six payments are loaded through pr_receive_payment after (c) and (d).

-- ---------------------------------------------------------------------
-- (b) Function [6 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee_due NUMERIC(12,2);
    v_paid    NUMERIC(12,2);
BEGIN
    SELECT fee_due INTO v_fee_due
    FROM students WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    -- COALESCE gives 0 when there are no payments, so the full fee is returned
    SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM payments WHERE student_id = p_student_id;

    RETURN v_fee_due - v_paid;
END;
$$;

-- ---------------------------------------------------------------------
-- (c) Procedure [8 marks]
-- fee_due is never updated; the balance is always fee_due - payments.
-- The audit row is written by the trigger in (d), not here.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INTEGER,
    p_amount     NUMERIC,
    p_paid_on    DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid amount: %. Amount must be greater than zero.', p_amount;
    END IF;

    -- Lock the student so two concurrent payments cannot overpay
    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance % for student %',
            p_amount, v_balance, p_student_id;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, COALESCE(p_paid_on, CURRENT_DATE));
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger [8 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_payment_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_payment_audit();

-- ---------------------------------------------------------------------
-- (a) continued: six payments through the procedure
-- ---------------------------------------------------------------------
CALL pr_receive_payment(1, 5000.00, DATE '2026-11-23');
CALL pr_receive_payment(1, 4000.00, DATE '2026-11-23');
CALL pr_receive_payment(2, 3000.00, DATE '2026-11-23');
CALL pr_receive_payment(1, 6000.00, DATE '2026-11-24');
CALL pr_receive_payment(2, 2000.00, DATE '2026-11-24');
CALL pr_receive_payment(2, 1500.00, DATE '2026-11-24');

-- Tests for (b)
SELECT fn_fee_balance(1) AS s1, fn_fee_balance(2) AS s2, fn_fee_balance(3) AS s3;
-- 0.00 | 5500.00 | 9000.00 (student 3 has no payments -> full fee)
-- SELECT fn_fee_balance(99); -- ERROR: Unknown student_id: 99

-- Tests for (c)
-- CALL pr_receive_payment(2, NULL); -- ERROR: Invalid amount
-- CALL pr_receive_payment(2, 0); -- ERROR: Invalid amount
-- CALL pr_receive_payment(2, -50); -- ERROR: Invalid amount
-- CALL pr_receive_payment(2, 6000.00); -- ERROR: exceeds balance 5500.00
SELECT * FROM students ORDER BY student_id;    -- fee_due unchanged

-- Test for (d)
SELECT * FROM payment_audit ORDER BY audit_id; -- 6 rows, one per payment

-- ---------------------------------------------------------------------
-- (e) View [5 marks]
-- LEFT JOIN keeps students with no payments; HAVING > 0 drops settled ones.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;

SELECT * FROM v_fee_balances;
-- 202001700 | Mwila Banda | 5500.00
-- 202001701 | Natasha Phiri | 9000.00 (Mapalo Chileshe fully paid -> excluded)

-- ---------------------------------------------------------------------
-- (f) Index [5 marks]
-- Equality column (student_id) first, range column (paid_on) second, so
-- the planner seeks to one student and reads only that date range.
-- ---------------------------------------------------------------------
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);
ANALYZE payments;

SET enable_seqscan = off;   -- demo only: tiny table would otherwise use Seq Scan
EXPLAIN ANALYZE
SELECT payment_id, amount, paid_on
FROM payments
WHERE student_id = 2
  AND paid_on BETWEEN DATE '2026-11-01' AND DATE '2026-11-30';
RESET enable_seqscan;
-- Plan: Index Scan using idx_payments_student_paid_on on payments
-- Index Cond: ((student_id = 2) AND (paid_on >= '2026-11-01') AND (paid_on <= '2026-11-30'))

-- ---------------------------------------------------------------------
-- (g) Scheduled job [6 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day is required';
    END IF;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
    FROM payments
    WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count,
        total_amount  = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_collections(DATE '2026-11-23');
CALL pr_refresh_collections(DATE '2026-11-24');
CALL pr_refresh_collections(DATE '2026-11-24');   -- rerun replaces the row
SELECT * FROM daily_collections ORDER BY collection_date;
-- 2026-11-23 | 3 | 12000.00
-- 2026-11-24 | 3 | 9500.00

-- Schedule daily at 01:00 for the previous day (requires pg_cron)
ALTER PROCEDURE q2.pr_refresh_collections(DATE) SET search_path = q2;
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q2_refresh_daily_collections',
    '0 1 * * *',
    $$CALL q2.pr_refresh_collections((CURRENT_DATE - 1)::date)$$
);
