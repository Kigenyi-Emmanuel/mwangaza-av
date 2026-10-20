-- Mwangaza AV (synthetic case study)
-- STAGE 13 in one file: build the cleaning area (staging). Executed on PostgreSQL 18.6; all 5 built-in checks pass.
-- Run order: once, in the mwangaza_av database, after Stage 12 (and Stage 12b). It creates empty tables only.
--
-- Purpose:
--   1. Stops with an error if the staging tables already exist, or if the raw data is missing.
--   2. Creates 16 staging tables. They look like the raw tables but have proper types (dates, numbers)
--      and extra columns for the cleaned values. Each keeps raw_row_id, so every row can be traced back.
--   3. Creates the customer_map table (which duplicate customer code belongs to which real customer).
--   4. Creates the quality-rule catalogue (staging.dq_rule, 13 rules; see docs/data-quality-rules.md),
--      and the two logs: staging.dq_issue (every fix or flag, with before and after) and
--      staging.rejected_row (every rejected row, with the reason).
--   5. Returns one result table at the end; every row should read PASS.
--
-- Safety: it only creates new tables and fills the 13-row rule catalogue. It deletes nothing.
-- Nothing is cleaned yet. The cleaning itself happens in Stages 14 and 15.

BEGIN;

-- Step 1: safety checks
DO $$
BEGIN
    IF (SELECT count(*) FROM raw.invoice) = 0 THEN
        RAISE EXCEPTION 'Stop: the raw data is missing (run Stages 5 to 12 first). Nothing was changed.';
    END IF;
    IF to_regclass('staging.customer') IS NOT NULL OR to_regclass('staging.dq_rule') IS NOT NULL THEN
        RAISE EXCEPTION 'Stop: the staging tables already exist. Nothing was changed.';
    END IF;
END $$;

-- Step 2: the rule catalogue and the two logs
CREATE TABLE staging.dq_rule (
    rule_id      text PRIMARY KEY,
    applies_to   text NOT NULL,
    description  text NOT NULL,
    action       text NOT NULL CHECK (action IN ('fix', 'reject', 'flag', 'keep'))
);

INSERT INTO staging.dq_rule (rule_id, applies_to, description, action) VALUES
    ('DQ01', 'all', 'Trim extra spaces, and write status and type words in one standard form (for example all lower case)', 'fix'),
    ('DQ02', 'all', 'Convert text to dates and numbers. A row that cannot be converted is rejected', 'reject'),
    ('DQ03', 'customer', 'Customers whose names match once capitals, extra spaces and a leading ''The'' are ignored are the same customer. The lowest customer code is kept as the real one', 'fix'),
    ('DQ04', 'customer', 'A blank or missing sector becomes ''Unknown'' and is logged', 'fix'),
    ('DQ05', 'quote, job, sales_order, rental_booking, invoice, payment', 'Customer codes of duplicate customers are replaced by the real customer code. The original code is kept in its own column', 'fix'),
    ('DQ06', 'invoice', 'An invoice that repeats another (same job, order or booking, same date, same amount) is rejected. The lowest invoice number is kept', 'reject'),
    ('DQ07', 'invoice', 'A due date before the invoice date is replaced by the invoice date plus the customer''s payment terms. The old value is logged', 'fix'),
    ('DQ08', 'payment_allocation', 'An allocation larger than its payment is reduced to the payment amount when the payment has only one allocation. The old value is logged', 'fix'),
    ('DQ09', 'all tables that point to another', 'A row that points to something that does not exist (customer, job, order, booking, asset, product, invoice, payment) is rejected', 'reject'),
    ('DQ10', 'payment_allocation', 'After the fixes, the total allocated to an invoice must not be more than the invoice total (amount plus VAT). Breaches are flagged', 'flag'),
    ('DQ11', 'rental_booking_line', 'Two bookings of the same asset on overlapping dates are flagged, not removed. Double-booking is a real event the analysis should find', 'flag'),
    ('DQ12', 'stock_movement', 'Any time a product''s running stock falls below zero is flagged', 'flag'),
    ('DQ13', 'all', 'Kept exactly as they are: the business patterns planted in the data (cost overruns, a loss-making job type, late payers, idle assets, dead stock, slow quotes). They are findings for the analysis, not errors', 'keep');

CREATE TABLE staging.dq_issue (
    issue_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rule_id       text NOT NULL REFERENCES staging.dq_rule (rule_id),
    table_name    text NOT NULL,
    raw_row_id    bigint,
    business_key  text,
    detail        text NOT NULL,
    value_before  text,
    value_after   text,
    logged_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE staging.rejected_row (
    rejected_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rule_id       text NOT NULL REFERENCES staging.dq_rule (rule_id),
    table_name    text NOT NULL,
    raw_row_id    bigint NOT NULL,
    business_key  text,
    reason        text NOT NULL,
    logged_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE staging.customer_map (
    raw_customer_code        text PRIMARY KEY,
    canonical_customer_code  text NOT NULL,
    reason                   text NOT NULL
);

-- Step 3: the typed staging tables. raw_row_id is the row's number in the raw table.
-- "original_customer_code" keeps the code written in raw; "customer_code" is the real customer after DQ05.
CREATE TABLE staging.customer (
    raw_row_id               bigint PRIMARY KEY,
    customer_code            text NOT NULL,
    customer_name            text NOT NULL,
    customer_name_key        text NOT NULL,   -- name in lower case, single spaces, no leading 'the'
    sector_name              text NOT NULL,   -- 'Unknown' when missing (DQ04)
    payment_terms_days       integer NOT NULL,
    created_date             date NOT NULL,
    canonical_customer_code  text NOT NULL,
    is_canonical             boolean NOT NULL,
    loaded_at                timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE staging.supplier (
    raw_row_id     bigint PRIMARY KEY,
    supplier_code  text NOT NULL,
    supplier_name  text NOT NULL,
    country        text NOT NULL,
    loaded_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE staging.product (
    raw_row_id             bigint PRIMARY KEY,
    sku                    text NOT NULL,
    product_name           text NOT NULL,
    product_category_name  text NOT NULL,
    supplier_code          text NOT NULL,
    list_price_ex_vat      numeric(14,2) NOT NULL,
    standard_cost          numeric(14,2) NOT NULL,
    is_active              boolean NOT NULL,
    loaded_at              timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE staging.asset (
    raw_row_id           bigint PRIMARY KEY,
    asset_tag            text NOT NULL,
    asset_name           text NOT NULL,
    asset_category_name  text NOT NULL,
    purchase_date        date NOT NULL,
    purchase_cost        numeric(14,2) NOT NULL,
    daily_rate_ex_vat    numeric(14,2) NOT NULL,
    status               text NOT NULL,
    retired_date         date,
    loaded_at            timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE staging.quote (
    raw_row_id             bigint PRIMARY KEY,
    quote_number           text NOT NULL,
    customer_code          text NOT NULL,
    original_customer_code text NOT NULL,
    office_name            text NOT NULL,
    division               text NOT NULL,
    quote_date             date NOT NULL,
    decision_date          date,
    status                 text NOT NULL,
    quoted_price_ex_vat    numeric(14,2) NOT NULL,
    quoted_cost            numeric(14,2) NOT NULL,
    loaded_at              timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE staging.job (
    raw_row_id             bigint PRIMARY KEY,
    job_number             text NOT NULL,
    quote_number           text,
    customer_code          text NOT NULL,
    original_customer_code text NOT NULL,
    office_name            text NOT NULL,
    job_type_name          text NOT NULL,
    start_date             date NOT NULL,
    end_date               date,
    status                 text NOT NULL,
    loaded_at              timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE staging.job_cost_line (
    raw_row_id          bigint PRIMARY KEY,
    job_number          text NOT NULL,
    cost_category_name  text NOT NULL,
    cost_date           date NOT NULL,
    description         text,
    quantity            numeric(12,2) NOT NULL,
    unit_cost           numeric(14,2) NOT NULL,
    sku                 text,
    loaded_at           timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE staging.sales_order (
    raw_row_id             bigint PRIMARY KEY,
    order_number           text NOT NULL,
    quote_number           text,
    customer_code          text NOT NULL,
    original_customer_code text NOT NULL,
    office_name            text NOT NULL,
    order_date             date NOT NULL,
    status                 text NOT NULL,
    loaded_at              timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE staging.sales_order_line (
    raw_row_id         bigint PRIMARY KEY,
    order_number       text NOT NULL,
    sku                text NOT NULL,
    quantity           integer NOT NULL,
    unit_price_ex_vat  numeric(14,2) NOT NULL,
    unit_cost          numeric(14,2) NOT NULL,
    loaded_at          timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE staging.stock_movement (
    raw_row_id       bigint PRIMARY KEY,
    sku              text NOT NULL,
    movement_date    date NOT NULL,
    movement_type    text NOT NULL,
    quantity_change  integer NOT NULL,
    unit_cost        numeric(14,2) NOT NULL,
    order_number     text,
    job_number       text,
    loaded_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE staging.rental_booking (
    raw_row_id             bigint PRIMARY KEY,
    booking_number         text NOT NULL,
    quote_number           text,
    customer_code          text NOT NULL,
    original_customer_code text NOT NULL,
    office_name            text NOT NULL,
    start_date             date NOT NULL,
    end_date               date NOT NULL,
    status                 text NOT NULL,
    loaded_at              timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE staging.rental_booking_line (
    raw_row_id         bigint PRIMARY KEY,
    booking_number     text NOT NULL,
    asset_tag          text NOT NULL,
    daily_rate_ex_vat  numeric(14,2) NOT NULL,
    loaded_at          timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE staging.maintenance_event (
    raw_row_id           bigint PRIMARY KEY,
    asset_tag            text NOT NULL,
    event_date           date NOT NULL,
    event_type           text NOT NULL,
    cost_amount          numeric(14,2) NOT NULL,
    days_out_of_service  integer NOT NULL,
    booking_number       text,
    loaded_at            timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE staging.invoice (
    raw_row_id             bigint PRIMARY KEY,
    invoice_number         text NOT NULL,
    division               text NOT NULL,
    job_number             text,
    order_number           text,
    booking_number         text,
    customer_code          text NOT NULL,
    original_customer_code text NOT NULL,
    invoice_date           date NOT NULL,
    due_date               date NOT NULL,
    original_due_date      date NOT NULL,   -- as it arrived in raw (DQ07 may change due_date)
    amount_ex_vat          numeric(14,2) NOT NULL,
    vat_amount             numeric(14,2) NOT NULL,
    loaded_at              timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE staging.payment (
    raw_row_id             bigint PRIMARY KEY,
    payment_reference      text NOT NULL,
    customer_code          text NOT NULL,
    original_customer_code text NOT NULL,
    payment_date           date NOT NULL,
    amount                 numeric(14,2) NOT NULL,
    payment_method         text NOT NULL,
    loaded_at              timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE staging.payment_allocation (
    raw_row_id                bigint PRIMARY KEY,
    payment_reference         text NOT NULL,
    invoice_number            text NOT NULL,
    allocated_amount          numeric(14,2) NOT NULL,   -- after DQ08
    original_allocated_amount numeric(14,2) NOT NULL,   -- as it arrived in raw
    loaded_at                 timestamptz NOT NULL DEFAULT now()
);

COMMIT;

-- Step 4: the check. One result table. Every row should say PASS.
SELECT what_we_check, expected, actual,
       CASE WHEN expected = actual THEN 'PASS' ELSE 'FAIL' END AS result
FROM (
    SELECT 1 AS n, 'Tables in the staging area (16 data + customer_map + rule catalogue + 2 logs)' AS what_we_check,
           '20' AS expected,
           (SELECT count(*) FROM information_schema.tables
             WHERE table_schema = 'staging' AND table_type = 'BASE TABLE')::text AS actual
    UNION ALL
    SELECT 2, 'Rules in the quality-rule catalogue', '13',
           (SELECT count(*) FROM staging.dq_rule)::text
    UNION ALL
    SELECT 3, 'Staging tables without a primary key (should be none)', '0',
           (SELECT count(*)
              FROM information_schema.tables t
             WHERE t.table_schema = 'staging' AND t.table_type = 'BASE TABLE'
               AND NOT EXISTS (SELECT 1 FROM information_schema.table_constraints c
                                WHERE c.table_schema = t.table_schema AND c.table_name = t.table_name
                                  AND c.constraint_type = 'PRIMARY KEY'))::text
    UNION ALL
    SELECT 4, 'Rows in the 16 staging data tables right now (nothing is cleaned yet)', '0',
           (SELECT sum(c)::text FROM (
                SELECT count(*) AS c FROM staging.customer UNION ALL SELECT count(*) FROM staging.supplier
                UNION ALL SELECT count(*) FROM staging.product UNION ALL SELECT count(*) FROM staging.asset
                UNION ALL SELECT count(*) FROM staging.quote UNION ALL SELECT count(*) FROM staging.job
                UNION ALL SELECT count(*) FROM staging.job_cost_line UNION ALL SELECT count(*) FROM staging.sales_order
                UNION ALL SELECT count(*) FROM staging.sales_order_line UNION ALL SELECT count(*) FROM staging.stock_movement
                UNION ALL SELECT count(*) FROM staging.rental_booking UNION ALL SELECT count(*) FROM staging.rental_booking_line
                UNION ALL SELECT count(*) FROM staging.maintenance_event UNION ALL SELECT count(*) FROM staging.invoice
                UNION ALL SELECT count(*) FROM staging.payment UNION ALL SELECT count(*) FROM staging.payment_allocation) s)
    UNION ALL
    SELECT 5, 'Rules with an action other than fix, reject, flag or keep (should be none)', '0',
           (SELECT count(*) FROM staging.dq_rule WHERE action NOT IN ('fix', 'reject', 'flag', 'keep'))::text
) t
ORDER BY n;
