-- Mwangaza AV (synthetic case study)
-- STAGE 14 in one file: clean the master data (customers, suppliers, products, assets) into staging.
-- Run it ONCE, in the mwangaza_av database, AFTER Stage 13. STATUS: written, not yet run.
--
-- What it does, in plain words:
--   1. Stops with an error if Stage 13 has not been run, or if staging already holds data.
--   2. Adds four small safe-reading helpers (staging.try_date, try_int, try_numeric, try_bool). They turn
--      text into a date or number, and return empty instead of an error when the text cannot be read.
--   3. Customers (rules DQ01 to DQ04): removes extra spaces, finds customers that are the same one entered
--      twice (same name once capitals, spaces and a leading "The" are ignored), keeps the lowest code as the
--      real customer, sets a blank sector to "Unknown", builds the customer map, and logs every change.
--   4. Suppliers, products and assets: reads the text into dates and numbers. Rows that cannot be read, or
--      that point to a category or supplier that does not exist, are set aside in staging.rejected_row.
--   5. Checks the work against the hidden answer key (generator.planted_error): did the cleaning find
--      exactly the duplicate customers and blank sectors that were planted, and nothing else?
--   6. Shows one result table at the end. Every row should say PASS.
--
-- Safe: one all-or-nothing block (BEGIN ... COMMIT). If a line fails, nothing from it is saved.
-- It never changes raw data. It never deletes anything.
-- The sector "Unknown" is only used in staging for now. It is added to core.sector when we load core.

BEGIN;

-- Step 1: safety checks
DO $$
BEGIN
    IF to_regclass('staging.customer') IS NULL THEN
        RAISE EXCEPTION 'Stop: Stage 13 has not been run yet. Nothing was changed.';
    END IF;
    IF (SELECT count(*) FROM staging.customer) > 0 OR (SELECT count(*) FROM staging.supplier) > 0
       OR (SELECT count(*) FROM staging.product) > 0 OR (SELECT count(*) FROM staging.asset) > 0 THEN
        RAISE EXCEPTION 'Stop: staging already holds master data. Nothing was changed.';
    END IF;
END $$;

-- Step 2: safe-reading helpers
CREATE OR REPLACE FUNCTION staging.try_date(t text) RETURNS date LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN RETURN NULLIF(btrim(t), '')::date; EXCEPTION WHEN others THEN RETURN NULL; END $$;

CREATE OR REPLACE FUNCTION staging.try_int(t text) RETURNS integer LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN RETURN NULLIF(btrim(t), '')::integer; EXCEPTION WHEN others THEN RETURN NULL; END $$;

CREATE OR REPLACE FUNCTION staging.try_numeric(t text) RETURNS numeric LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN RETURN NULLIF(btrim(t), '')::numeric; EXCEPTION WHEN others THEN RETURN NULL; END $$;

CREATE OR REPLACE FUNCTION staging.try_bool(t text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN lower(btrim(t)) IN ('true', 't', 'yes', 'y', '1') THEN true
                WHEN lower(btrim(t)) IN ('false', 'f', 'no', 'n', '0') THEN false
                ELSE NULL END $$;

-- Step 3a: customers. Read and clean each raw row.
CREATE TEMP TABLE tmp_c0 ON COMMIT DROP AS
SELECT r.raw_row_id,
       btrim(coalesce(r.customer_code, '')) AS customer_code,
       r.customer_name AS raw_name,
       regexp_replace(btrim(coalesce(r.customer_name, '')), '\s+', ' ', 'g') AS customer_name,
       regexp_replace(regexp_replace(lower(btrim(coalesce(r.customer_name, ''))), '^the\s+', ''), '\s+', ' ', 'g') AS name_key,
       r.sector_name AS raw_sector,
       CASE WHEN r.sector_name IS NULL OR btrim(r.sector_name) = '' THEN NULL ELSE btrim(r.sector_name) END AS sector_clean,
       staging.try_int(r.payment_terms_days) AS terms,
       staging.try_date(r.created_date) AS created
FROM raw.customer r;

CREATE TEMP TABLE tmp_c1 ON COMMIT DROP AS
SELECT c.*,
       (c.customer_code = '' OR c.customer_name = '' OR c.terms IS NULL OR c.created IS NULL) AS unreadable,
       (c.sector_clean IS NOT NULL AND c.sector_clean NOT IN (SELECT sector_name FROM core.sector)) AS bad_sector
FROM tmp_c0 c;

-- rows that cannot be used are set aside, with the reason
INSERT INTO staging.rejected_row (rule_id, table_name, raw_row_id, business_key, reason)
SELECT 'DQ02', 'customer', raw_row_id, customer_code, 'Code, name, payment terms or created date missing or unreadable'
FROM tmp_c1 WHERE unreadable
UNION ALL
SELECT 'DQ09', 'customer', raw_row_id, customer_code, 'Sector "' || sector_clean || '" does not exist in the sector list'
FROM tmp_c1 WHERE NOT unreadable AND bad_sector;

-- the good rows go to staging. The real customer in each group of duplicates is the one with the lowest code.
INSERT INTO staging.customer
    (raw_row_id, customer_code, customer_name, customer_name_key, sector_name, payment_terms_days,
     created_date, canonical_customer_code, is_canonical)
SELECT raw_row_id, customer_code, customer_name, name_key, coalesce(sector_clean, 'Unknown'), terms, created,
       min(customer_code) OVER (PARTITION BY name_key),
       customer_code = min(customer_code) OVER (PARTITION BY name_key)
FROM tmp_c1
WHERE NOT unreadable AND NOT bad_sector;

-- the map: every customer code points to its real customer
INSERT INTO staging.customer_map (raw_customer_code, canonical_customer_code, reason)
SELECT customer_code, canonical_customer_code,
       CASE WHEN is_canonical THEN 'Real customer'
            ELSE 'Duplicate: same name as ' || canonical_customer_code END
FROM staging.customer;

-- log every change (rules DQ01, DQ03, DQ04)
INSERT INTO staging.dq_issue (rule_id, table_name, raw_row_id, business_key, detail, value_before, value_after)
SELECT 'DQ01', 'customer', raw_row_id, customer_code, 'Extra spaces removed from the name', raw_name, customer_name
FROM tmp_c1
WHERE NOT unreadable AND NOT bad_sector AND raw_name <> customer_name
UNION ALL
SELECT 'DQ03', 'customer', raw_row_id, customer_code, 'Same customer as ' || canonical_customer_code,
       customer_name, canonical_customer_code
FROM staging.customer
WHERE NOT is_canonical
UNION ALL
SELECT 'DQ04', 'customer', raw_row_id, customer_code, 'Sector missing; set to Unknown',
       CASE WHEN raw_sector IS NULL THEN 'NULL' ELSE 'blank' END, 'Unknown'
FROM tmp_c1
WHERE NOT unreadable AND NOT bad_sector AND sector_clean IS NULL;

-- Step 3b: suppliers
CREATE TEMP TABLE tmp_s0 ON COMMIT DROP AS
SELECT r.raw_row_id,
       btrim(coalesce(r.supplier_code, '')) AS supplier_code,
       regexp_replace(btrim(coalesce(r.supplier_name, '')), '\s+', ' ', 'g') AS supplier_name,
       btrim(coalesce(r.country, '')) AS country
FROM raw.supplier r;

INSERT INTO staging.rejected_row (rule_id, table_name, raw_row_id, business_key, reason)
SELECT 'DQ02', 'supplier', raw_row_id, supplier_code, 'Code, name or country missing'
FROM tmp_s0 WHERE supplier_code = '' OR supplier_name = '' OR country = '';

INSERT INTO staging.supplier (raw_row_id, supplier_code, supplier_name, country)
SELECT raw_row_id, supplier_code, supplier_name, country
FROM tmp_s0 WHERE supplier_code <> '' AND supplier_name <> '' AND country <> '';

-- Step 3c: products
CREATE TEMP TABLE tmp_p0 ON COMMIT DROP AS
SELECT r.raw_row_id,
       btrim(coalesce(r.sku, '')) AS sku,
       regexp_replace(btrim(coalesce(r.product_name, '')), '\s+', ' ', 'g') AS product_name,
       btrim(coalesce(r.product_category_name, '')) AS category,
       btrim(coalesce(r.supplier_code, '')) AS supplier_code,
       staging.try_numeric(r.list_price_ex_vat) AS price,
       staging.try_numeric(r.standard_cost) AS cost,
       staging.try_bool(r.is_active) AS active
FROM raw.product r;

CREATE TEMP TABLE tmp_p1 ON COMMIT DROP AS
SELECT p.*,
       (p.sku = '' OR p.product_name = '' OR p.price IS NULL OR p.cost IS NULL OR p.active IS NULL) AS unreadable,
       (p.category NOT IN (SELECT product_category_name FROM core.product_category)
        OR p.supplier_code NOT IN (SELECT supplier_code FROM staging.supplier)) AS link_missing
FROM tmp_p0 p;

INSERT INTO staging.rejected_row (rule_id, table_name, raw_row_id, business_key, reason)
SELECT 'DQ02', 'product', raw_row_id, sku, 'SKU, name, price, cost or active flag missing or unreadable'
FROM tmp_p1 WHERE unreadable
UNION ALL
SELECT 'DQ09', 'product', raw_row_id, sku, 'Category or supplier does not exist'
FROM tmp_p1 WHERE NOT unreadable AND link_missing;

INSERT INTO staging.product
    (raw_row_id, sku, product_name, product_category_name, supplier_code, list_price_ex_vat, standard_cost, is_active)
SELECT raw_row_id, sku, product_name, category, supplier_code, price, cost, active
FROM tmp_p1 WHERE NOT unreadable AND NOT link_missing;

-- Step 3d: assets
CREATE TEMP TABLE tmp_a0 ON COMMIT DROP AS
SELECT r.raw_row_id,
       btrim(coalesce(r.asset_tag, '')) AS asset_tag,
       regexp_replace(btrim(coalesce(r.asset_name, '')), '\s+', ' ', 'g') AS asset_name,
       btrim(coalesce(r.asset_category_name, '')) AS category,
       staging.try_date(r.purchase_date) AS purchase_date,
       staging.try_numeric(r.purchase_cost) AS purchase_cost,
       staging.try_numeric(r.daily_rate_ex_vat) AS daily_rate,
       lower(btrim(coalesce(r.status, ''))) AS status,
       staging.try_date(r.retired_date) AS retired_date,
       (btrim(coalesce(r.retired_date, '')) <> '') AS has_retired_text
FROM raw.asset r;

CREATE TEMP TABLE tmp_a1 ON COMMIT DROP AS
SELECT a.*,
       (a.asset_tag = '' OR a.asset_name = '' OR a.purchase_date IS NULL OR a.purchase_cost IS NULL
        OR a.daily_rate IS NULL OR (a.has_retired_text AND a.retired_date IS NULL)) AS unreadable,
       (a.category NOT IN (SELECT asset_category_name FROM core.asset_category)
        OR a.status NOT IN ('active', 'in_repair', 'retired')) AS link_missing
FROM tmp_a0 a;

INSERT INTO staging.rejected_row (rule_id, table_name, raw_row_id, business_key, reason)
SELECT 'DQ02', 'asset', raw_row_id, asset_tag, 'Tag, name, date or price missing or unreadable'
FROM tmp_a1 WHERE unreadable
UNION ALL
SELECT 'DQ09', 'asset', raw_row_id, asset_tag, 'Category does not exist, or status is not one of active, in_repair, retired'
FROM tmp_a1 WHERE NOT unreadable AND link_missing;

INSERT INTO staging.asset
    (raw_row_id, asset_tag, asset_name, asset_category_name, purchase_date, purchase_cost,
     daily_rate_ex_vat, status, retired_date)
SELECT raw_row_id, asset_tag, asset_name, category, purchase_date, purchase_cost, daily_rate, status, retired_date
FROM tmp_a1 WHERE NOT unreadable AND NOT link_missing;

COMMIT;

-- Step 4: the check. One result table. Every row should say PASS.
SELECT what_we_check, expected, actual,
       CASE WHEN expected = actual THEN 'PASS' ELSE 'FAIL' END AS result
FROM (
    SELECT 1 AS n, 'Customers: raw rows equal staging rows plus rejected rows' AS what_we_check,
           (SELECT count(*) FROM raw.customer)::text AS expected,
           ((SELECT count(*) FROM staging.customer)
            + (SELECT count(*) FROM staging.rejected_row WHERE table_name = 'customer'))::text AS actual
    UNION ALL
    SELECT 2, 'Suppliers: raw rows equal staging rows plus rejected rows',
           (SELECT count(*) FROM raw.supplier)::text,
           ((SELECT count(*) FROM staging.supplier)
            + (SELECT count(*) FROM staging.rejected_row WHERE table_name = 'supplier'))::text
    UNION ALL
    SELECT 3, 'Products: raw rows equal staging rows plus rejected rows',
           (SELECT count(*) FROM raw.product)::text,
           ((SELECT count(*) FROM staging.product)
            + (SELECT count(*) FROM staging.rejected_row WHERE table_name = 'product'))::text
    UNION ALL
    SELECT 4, 'Assets: raw rows equal staging rows plus rejected rows',
           (SELECT count(*) FROM raw.asset)::text,
           ((SELECT count(*) FROM staging.asset)
            + (SELECT count(*) FROM staging.rejected_row WHERE table_name = 'asset'))::text
    UNION ALL
    SELECT 5, 'Duplicate customers found (planted X02: register D02)',
           (SELECT central::int FROM generator.parameter WHERE parameter_id = 'D02')::text,
           (SELECT count(*) FROM staging.customer WHERE NOT is_canonical)::text
    UNION ALL
    SELECT 6, 'Customers whose missing sector was set to Unknown (planted X05: register D05)',
           (SELECT central::int FROM generator.parameter WHERE parameter_id = 'D05')::text,
           (SELECT count(*) FROM staging.customer WHERE sector_name = 'Unknown')::text
    UNION ALL
    SELECT 7, 'Customer map has one row for every customer in staging',
           (SELECT count(*) FROM staging.customer)::text,
           (SELECT count(*) FROM staging.customer_map)::text
    UNION ALL
    SELECT 8, 'Map entries whose real customer does not exist (should be none)', '0',
           (SELECT count(*) FROM staging.customer_map m
              LEFT JOIN staging.customer c ON c.customer_code = m.canonical_customer_code AND c.is_canonical
             WHERE c.customer_code IS NULL)::text
    UNION ALL
    SELECT 9, 'Real customers equal the register number of customers (G06)',
           (SELECT central::int FROM generator.parameter WHERE parameter_id = 'G06')::text,
           (SELECT count(*) FROM staging.customer WHERE is_canonical)::text
    UNION ALL
    SELECT 10, 'Master-data rows set aside as rejected (our generated data should have none)', '0',
           (SELECT count(*) FROM staging.rejected_row
             WHERE table_name IN ('customer', 'supplier', 'product', 'asset'))::text
    UNION ALL
    SELECT 11, 'Customer fixes logged for duplicates and missing sectors (rules DQ03 and DQ04)',
           ((SELECT central::int FROM generator.parameter WHERE parameter_id = 'D02')
            + (SELECT central::int FROM generator.parameter WHERE parameter_id = 'D05'))::text,
           (SELECT count(*) FROM staging.dq_issue WHERE rule_id IN ('DQ03', 'DQ04'))::text
    UNION ALL
    SELECT 12, 'Answer key: planted duplicates mapped to the wrong real customer (should be none)', '0',
           (SELECT count(*) FROM generator.planted_error pe
             WHERE pe.planted_id = 'X02'
               AND NOT EXISTS (SELECT 1 FROM staging.customer_map m
                                WHERE m.raw_customer_code = pe.business_key
                                  AND m.canonical_customer_code = substring(pe.detail from 'Duplicate of (C[0-9]+)')))::text
    UNION ALL
    SELECT 13, 'Answer key: planted blank-sector customers that did not become Unknown (should be none)', '0',
           (SELECT count(*) FROM generator.planted_error pe
              JOIN staging.customer c ON c.customer_code = pe.business_key
             WHERE pe.planted_id = 'X05' AND c.sector_name <> 'Unknown')::text
    UNION ALL
    SELECT 14, 'False alarms: customers flagged as duplicates that are not in the answer key (should be none)', '0',
           (SELECT count(*) FROM staging.customer c
             WHERE NOT c.is_canonical
               AND c.customer_code NOT IN (SELECT business_key FROM generator.planted_error WHERE planted_id = 'X02'))::text
    UNION ALL
    SELECT 15, 'Supplier codes used more than once in staging (should be none)', '0',
           (SELECT count(*) - count(DISTINCT supplier_code) FROM staging.supplier)::text
) t
ORDER BY n;
