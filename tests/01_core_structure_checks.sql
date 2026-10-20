-- Mwangaza AV (synthetic case study)
-- Structure checks for the core layer. Run in the mwangaza_av database after all core scripts.
-- Executed on PostgreSQL 18.6; passed. Output not yet saved in tests/results.

-- Check 1: how many tables are in core?  Expected result: 22
SELECT count(*) AS tables_in_core
FROM information_schema.tables
WHERE table_schema = 'core' AND table_type = 'BASE TABLE';

-- Check 2: list them.  Expected: 22 names, including invoice, payment and payment_allocation.
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'core' AND table_type = 'BASE TABLE'
ORDER BY table_name;

-- Check 3 (try to break it): this insert must FAIL, because it gives an invoice two sources.
-- Expected: an error that mentions the constraint ck_invoice_one_source. Nothing is saved when it fails.
INSERT INTO core.invoice
    (invoice_number, division, job_id, sales_order_id, customer_id, invoice_date, due_date, amount_ex_vat)
VALUES
    ('TEST-001', 'projects', 1, 1, 1, DATE '2026-01-01', DATE '2026-01-31', 100);
