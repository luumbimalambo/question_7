-- ICT371 Advanced Database | Question 7: Water Meter Readings and Billing
-- Student: Luumbi Malambo | Student No: 202408554

DROP TABLE IF EXISTS receivable_snapshot, bills, readings, customers CASCADE;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);
CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INTEGER NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE NOT NULL,
    previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT chk_reading_month_first_day CHECK (EXTRACT(DAY FROM reading_month) = 1),
    CONSTRAINT uq_customer_month UNIQUE (customer_id, reading_month)
);
CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INTEGER NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on      DATE NOT NULL,
    CONSTRAINT chk_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);
CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(14,2) NOT NULL
);

INSERT INTO customers (full_name) VALUES ('Agnes Mulenga'), ('Boniface Sinkala'), ('Catherine Lweendo');

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2) AS $$
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Invalid consumption: % (must not be NULL or negative)', p_units;
    END IF;

    IF p_units <= 10 THEN
        RETURN ROUND(p_units * 5, 2);                    -- first 10 units at K5
    ELSE
        RETURN ROUND(10 * 5 + (p_units - 10) * 8, 2);    -- K50 + K8 for each unit above 10
    END IF;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- (d) Trigger (installed before readings are loaded) ---------------------------
CREATE OR REPLACE FUNCTION trg_reading_check() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) is below previous_reading (%)',
            NEW.current_reading, NEW.previous_reading;   -- row is not stored
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_reading_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW EXECUTE FUNCTION trg_reading_check();

-- (a) continued: six readings (units: 0, 10, 15, 4, 25, 10)
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, (date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::date, 100,  100),   -- 0 units
    (1, (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date,  100,  110),   -- exactly 10
    (2, (date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::date,  50,   65),   -- 15
    (2, (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date,   65,   69),   -- 4
    (3, (date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::date, 200,  225),   -- 25
    (3, (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date,  225,  235);   -- exactly 10

SELECT * FROM readings ORDER BY reading_id;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INTEGER, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_units NUMERIC;
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date is required';
    END IF;

    SELECT current_reading - previous_reading INTO v_units
    FROM readings WHERE reading_id = p_reading_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;

    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, fn_water_charge(v_units), 0, p_due_on);
END;
$$;

-- Generate bills for all six readings (some overdue, some not yet due)
CALL pr_generate_bill(1, CURRENT_DATE - 20);
CALL pr_generate_bill(2, CURRENT_DATE + 10);
CALL pr_generate_bill(3, CURRENT_DATE - 20);
CALL pr_generate_bill(4, CURRENT_DATE - 5);
CALL pr_generate_bill(5, CURRENT_DATE - 20);
CALL pr_generate_bill(6, CURRENT_DATE + 10);

-- Record some payments
UPDATE bills SET amount_paid = charge WHERE reading_id = 3;   -- fully paid
UPDATE bills SET amount_paid = 100    WHERE reading_id = 5;   -- partly paid

SELECT * FROM bills ORDER BY bill_id;

-- Tests
SELECT u AS units, fn_water_charge(u) AS charge
FROM (VALUES (0), (4), (10), (15), (25), (10.5)) AS t(u);    -- 0, 20, 50, 90, 170, 54.00
DO $$
BEGIN
    BEGIN PERFORM fn_water_charge(NULL);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN PERFORM fn_water_charge(-3);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_generate_bill(999, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_generate_bill(1, CURRENT_DATE);           -- already billed
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    -- direct SQL import with a lower current reading is rejected and not stored
    BEGIN INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
          VALUES (1, date_trunc('month', CURRENT_DATE)::date, 110, 105);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
END $$;
SELECT COUNT(*) AS readings_count FROM readings;    -- still 6

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name AS customer_name,
       b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r  ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills ORDER BY due_on;

-- (f) Index ----------------------------------------------------------------
-- Overdue searches only care about UNPAID bills, filtered by due date. A partial
-- index on due_on limited to unpaid bills is small and fits the query exactly.
CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;
ANALYZE bills;
SET enable_seqscan = off;   -- tiny table: force the plan to show the index
EXPLAIN
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills
WHERE amount_paid < charge AND due_on < CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
    FROM bills
    WHERE amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE SET total_due = EXCLUDED.total_due;
END;
$$;

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();   -- rerun replaces today's total
SELECT * FROM receivable_snapshot;

-- Scheduling with pg_cron. If pg_cron is not installed, this prints a notice instead
-- of failing, so the rest of the script is not rolled back.
DO $do$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.schedule('refresh_receivables_daily', '30 0 * * *',
        $$CALL pr_refresh_receivables()$$);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron not available, job not scheduled: %', SQLERRM;
END $do$;

-- Inspect the job (works only where pg_cron is installed):
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, runid, status, return_message, start_time, end_time
--   FROM cron.job_run_details ORDER BY start_time DESC LIMIT 20;
