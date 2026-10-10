-- Mwangaza AV (synthetic case study)
-- STAGE 5 in one file. Run it once, in the mwangaza_av database.
-- STATUS: written, not yet run.
--
-- What it does, in plain words:
--   1. Stops with an error if the customer or supplier table already has rows. Nothing is changed.
--   2. Adds a "code" column to customer and supplier (so records can be linked by code).
--   3. Creates 16 "landing area" (raw) tables. Every column is text, so messy data can land.
--   4. Shows one result table at the end. Every row should say PASS.
--
-- Safe: it only adds new things. It deletes nothing. Running it twice does no harm.

-- Step 1: safety check
DO $$
BEGIN
    IF (SELECT count(*) FROM core.customer) > 0 OR (SELECT count(*) FROM core.supplier) > 0 THEN
        RAISE EXCEPTION 'Stop: customer or supplier already has rows. Nothing was changed.';
    END IF;
END $$;

-- Step 2: add the code columns
ALTER TABLE core.customer ADD COLUMN IF NOT EXISTS customer_code text NOT NULL UNIQUE;
ALTER TABLE core.supplier ADD COLUMN IF NOT EXISTS supplier_code text NOT NULL UNIQUE;

-- Step 3: the landing-area tables.
-- Rules for this area: every data column is text; no keys, links or rules (duplicates and broken
-- links must be able to arrive); rows point to each other by code or number, like a real export.
-- Two helper columns on each table: raw_row_id (order of arrival) and loaded_at.
-- Lookup lists (sector, office, job type and so on) are not here: they were loaded straight to core.

CREATE TABLE IF NOT EXISTS raw.customer (
    raw_row_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loaded_at           timestamptz NOT NULL DEFAULT now(),
    customer_code       text,
    customer_name       text,
    sector_name         text,
    payment_terms_days  text,
    created_date        text
);

CREATE TABLE IF NOT EXISTS raw.supplier (
    raw_row_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loaded_at      timestamptz NOT NULL DEFAULT now(),
    supplier_code  text,
    supplier_name  text,
    country        text
);

CREATE TABLE IF NOT EXISTS raw.product (
    raw_row_id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loaded_at             timestamptz NOT NULL DEFAULT now(),
    sku                   text,
    product_name          text,
    product_category_name text,
    supplier_code         text,
    list_price_ex_vat     text,
    standard_cost         text,
    is_active             text
);

CREATE TABLE IF NOT EXISTS raw.asset (
    raw_row_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loaded_at            timestamptz NOT NULL DEFAULT now(),
    asset_tag            text,
    asset_name           text,
    asset_category_name  text,
    purchase_date        text,
    purchase_cost        text,
    daily_rate_ex_vat    text,
    status               text,
    retired_date         text
);

CREATE TABLE IF NOT EXISTS raw.quote (
    raw_row_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loaded_at            timestamptz NOT NULL DEFAULT now(),
    quote_number         text,
    customer_code        text,
    office_name          text,
    division             text,
    quote_date           text,
    decision_date        text,
    status               text,
    quoted_price_ex_vat  text,
    quoted_cost          text
);

CREATE TABLE IF NOT EXISTS raw.job (
    raw_row_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loaded_at      timestamptz NOT NULL DEFAULT now(),
    job_number     text,
    quote_number   text,
    customer_code  text,
    office_name    text,
    job_type_name  text,
    start_date     text,
    end_date       text,
    status         text
);

CREATE TABLE IF NOT EXISTS raw.job_cost_line (
    raw_row_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loaded_at           timestamptz NOT NULL DEFAULT now(),
    job_number          text,
    cost_category_name  text,
    cost_date           text,
    description         text,
    quantity            text,
    unit_cost           text,
    sku                 text
);

CREATE TABLE IF NOT EXISTS raw.sales_order (
    raw_row_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loaded_at      timestamptz NOT NULL DEFAULT now(),
    order_number   text,
    quote_number   text,
    customer_code  text,
    office_name    text,
    order_date     text,
    status         text
);

CREATE TABLE IF NOT EXISTS raw.sales_order_line (
    raw_row_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loaded_at          timestamptz NOT NULL DEFAULT now(),
    order_number       text,
    sku                text,
    quantity           text,
    unit_price_ex_vat  text,
    unit_cost          text
);

CREATE TABLE IF NOT EXISTS raw.stock_movement (
    raw_row_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loaded_at        timestamptz NOT NULL DEFAULT now(),
    sku              text,
    movement_date    text,
    movement_type    text,
    quantity_change  text,
    unit_cost        text,
    order_number     text,
    job_number       text
);

CREATE TABLE IF NOT EXISTS raw.rental_booking (
    raw_row_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loaded_at       timestamptz NOT NULL DEFAULT now(),
    booking_number  text,
    quote_number    text,
    customer_code   text,
    office_name     text,
    start_date      text,
    end_date        text,
    status          text
);

CREATE TABLE IF NOT EXISTS raw.rental_booking_line (
    raw_row_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loaded_at          timestamptz NOT NULL DEFAULT now(),
    booking_number     text,
    asset_tag          text,
    daily_rate_ex_vat  text
);

CREATE TABLE IF NOT EXISTS raw.maintenance_event (
    raw_row_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loaded_at            timestamptz NOT NULL DEFAULT now(),
    asset_tag            text,
    event_date           text,
    event_type           text,
    cost_amount          text,
    days_out_of_service  text,
    booking_number       text
);

CREATE TABLE IF NOT EXISTS raw.invoice (
    raw_row_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loaded_at       timestamptz NOT NULL DEFAULT now(),
    invoice_number  text,
    division        text,
    job_number      text,
    order_number    text,
    booking_number  text,
    customer_code   text,
    invoice_date    text,
    due_date        text,
    amount_ex_vat   text,
    vat_amount      text
);

CREATE TABLE IF NOT EXISTS raw.payment (
    raw_row_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loaded_at          timestamptz NOT NULL DEFAULT now(),
    payment_reference  text,
    customer_code      text,
    payment_date       text,
    amount             text,
    payment_method     text
);

CREATE TABLE IF NOT EXISTS raw.payment_allocation (
    raw_row_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loaded_at          timestamptz NOT NULL DEFAULT now(),
    payment_reference  text,
    invoice_number     text,
    allocated_amount   text
);


-- Step 4: the check. One result table. Every row should say PASS.
SELECT what_we_check, expected, actual,
       CASE WHEN expected = actual THEN 'PASS' ELSE 'FAIL' END AS result
FROM (
    SELECT 1 AS n, 'Landing-area (raw) tables created' AS what_we_check, '16' AS expected,
           (SELECT count(*) FROM information_schema.tables
             WHERE table_schema = 'raw' AND table_type = 'BASE TABLE')::text AS actual
    UNION ALL
    SELECT 2, 'Raw columns that are NOT text (should be none)', '0',
           (SELECT count(*) FROM information_schema.columns
             WHERE table_schema = 'raw'
               AND column_name NOT IN ('raw_row_id', 'loaded_at')
               AND data_type <> 'text')::text
    UNION ALL
    SELECT 3, 'New code columns in core (customer_code, supplier_code)', '2',
           (SELECT count(*) FROM information_schema.columns
             WHERE table_schema = 'core'
               AND column_name IN ('customer_code', 'supplier_code'))::text
) t
ORDER BY n;
