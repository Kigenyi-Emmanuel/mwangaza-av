-- Mwangaza AV (synthetic case study)
-- STAGE 6 in one file: create fake customers and suppliers in the landing area (raw).
-- Run order: once, in the mwangaza_av database. Executed on PostgreSQL 18.6; all 8 built-in checks pass.
--
-- Purpose:
--   1. Stops with an error if raw customers or suppliers already have rows. Nothing is changed.
--   2. Creates a small "answer key" area called generator. It holds the numbers from the
--      assumptions register, hidden facts about each customer, and a list of every planted mistake.
--   3. Creates the customers and suppliers in raw, with some mistakes planted on purpose:
--        - the same customer entered twice with the name spelled differently (planted error X02)
--        - customers with the sector left blank (planted error X05)
--      It also secretly marks a few customers as habitual late payers (X08), for later stages.
--   4. Returns one result table at the end; every row should read PASS.
--
-- Safety: the whole script is one all-or-nothing block (BEGIN ... COMMIT). If a line fails,
-- nothing from it is saved. It deletes nothing that exists.
-- The numbers below are a copy of docs/assumptions_register.xlsx. If the register workbook changes,
-- this copy must be updated too.
-- Same seed gives the same data on the same setup. We have not tested other PostgreSQL versions.
-- All names are made up from word lists. Any match with a real organisation is coincidence.

BEGIN;

-- Step 1: safety check
DO $$
BEGIN
    IF (SELECT count(*) FROM raw.customer) > 0 OR (SELECT count(*) FROM raw.supplier) > 0 THEN
        RAISE EXCEPTION 'Stop: raw.customer or raw.supplier already has rows. Nothing was changed.';
    END IF;
    IF to_regclass('generator.parameter') IS NOT NULL THEN
        RAISE EXCEPTION 'Stop: the generator area already exists. Nothing was changed.';
    END IF;
END $$;

-- Step 2: the answer key area
CREATE SCHEMA IF NOT EXISTS generator;
COMMENT ON SCHEMA generator IS 'Answer key for the synthetic data: parameters, hidden customer traits and the list of planted errors. Not part of the company records.';

CREATE TABLE generator.parameter (
    parameter_id    text PRIMARY KEY,
    parameter_name  text NOT NULL,
    low             numeric,
    central         numeric,
    high            numeric,
    unit            text
);

-- Copy of the numeric rows of docs/assumptions_register.xlsx (54 rows)
INSERT INTO generator.parameter (parameter_id, parameter_name, low, central, high, unit) VALUES
    ('G03', 'Random seed for setseed() (must be between -1 and 1)', NULL, 0.42, NULL, 'x'),
    ('G06', 'Customers', 120, 150, 180, 'count'),
    ('G08', 'Awarded jobs over the window', 90, 120, 150, 'count'),
    ('G09', 'Products in catalogue', 60, 80, 100, 'count'),
    ('G10', 'Suppliers', 10, 15, 20, 'count'),
    ('G11', 'Rental assets', 90, 120, 150, 'count'),
    ('C01', 'Quote win rate: projects', 0.3, 0.45, 0.6, '%'),
    ('C02', 'Quote win rate: products', 0.5, 0.65, 0.8, '%'),
    ('C03', 'Quote win rate: rentals', 0.6, 0.72, 0.85, '%'),
    ('C04', 'Days from quote to decision', 3, 14, 60, 'days'),
    ('C05', 'PLANTED: win-rate drop when the decision takes over 45 days (percentage points)', 10, 15, 20, 'pp'),
    ('M01', 'Product margin on price', 0.06, 0.18, 0.3, '%'),
    ('M02', 'Labour share of project revenue', 0.17, 0.3, 0.35, '%'),
    ('M03', 'Quoted gross margin on projects', 0.25, 0.35, 0.48, '%'),
    ('M04', 'PLANTED: labour cost overrun on commissioning-heavy job types', 0.15, 0.25, 0.4, '%'),
    ('M05', 'Labour cost overrun on other job types', -0.05, 0.05, 0.15, '%'),
    ('M06', 'PLANTED: average actual margin of one loss-making job type', -0.1, -0.05, 0, '%'),
    ('M07', 'Job value (KES, before VAT)', 150000, 1200000, 15000000, 'KES'),
    ('M08', 'Product list price (KES)', 2000, 45000, 900000, 'KES'),
    ('M09', 'Rental daily rate (KES)', 1500, 12000, 80000, 'KES'),
    ('R01', 'Utilisation of event-type kit', 0.3, 0.4, 0.5, '%'),
    ('R02', 'Utilisation of core fleet items', 0.55, 0.65, 0.75, '%'),
    ('R03', 'PLANTED: share of fleet used under 10% of the time', 0.05, 0.07, 0.1, '%'),
    ('R04', 'Time lost to damage repairs', 0.03, 0.04, 0.05, '%'),
    ('R05', 'Repair cost per damage event, as share of asset purchase cost', 0.02, 0.08, 0.25, '%'),
    ('R06', 'Seasonal peak vs quiet month (demand factor)', 1, 1.2, 1.4, 'x'),
    ('R07', 'PLANTED: double-booked asset pairs', 10, 15, 20, 'count'),
    ('P01', 'Payment terms on invoices (days)', 14, 30, 60, 'days'),
    ('P02', 'Days from invoice to payment: government', 60, 110, 180, 'days'),
    ('P03', 'Days from invoice to payment: corporate', 25, 45, 75, 'days'),
    ('P04', 'Days from invoice to payment: hospitality', 30, 60, 90, 'days'),
    ('P05', 'Days from invoice to payment: other sectors', 30, 50, 90, 'days'),
    ('P06', 'Target outcome: share of invoices paid over 30 days after invoice', 0.5, 0.6, 0.7, '%'),
    ('P07', 'PLANTED: habitual late payers (customers)', 3, 4, 6, 'count'),
    ('P08', 'Share of invoices paid in parts', 0.1, 0.15, 0.25, '%'),
    ('P09', 'Share of payments that cover several invoices', 0.1, 0.2, 0.3, '%'),
    ('P10', 'Invoices per job (progress billing)', 1, 2.5, 4, 'x'),
    ('P11', 'VAT rate', 0.16, 0.16, 0.16, '%'),
    ('S01', 'PLANTED: products with no sale for 12 months or more', 8, 10, 14, 'count'),
    ('D01', 'PLANTED: duplicate invoice pairs', 8, 12, 16, 'count'),
    ('D02', 'PLANTED: customer name variants (case or spacing)', 4, 6, 8, 'count'),
    ('D03', 'PLANTED: allocations larger than the payment', 4, 6, 10, 'count'),
    ('D04', 'PLANTED: invoices with due date before invoice date', 5, 8, 12, 'count'),
    ('D05', 'PLANTED: customers with a missing sector', 3, 5, 8, 'count'),
    ('SM1', 'Customer share: Hospitality', NULL, 0.2, NULL, '%'),
    ('SM2', 'Customer share: Corporate', NULL, 0.25, NULL, '%'),
    ('SM3', 'Customer share: Education', NULL, 0.15, NULL, '%'),
    ('SM4', 'Customer share: Government', NULL, 0.12, NULL, '%'),
    ('SM5', 'Customer share: Non-profit', NULL, 0.1, NULL, '%'),
    ('SM6', 'Customer share: Events and media', NULL, 0.1, NULL, '%'),
    ('SM7', 'Customer share: Healthcare', NULL, 0.08, NULL, '%'),
    ('PT1', 'Share of customers on 14-day payment terms', NULL, 0.2, NULL, '%'),
    ('PT2', 'Share of customers on 30-day payment terms', NULL, 0.6, NULL, '%'),
    ('PT3', 'Share of customers on 60-day payment terms', NULL, 0.2, NULL, '%');

CREATE TABLE generator.customer_profile (
    customer_code           text PRIMARY KEY,
    customer_name           text NOT NULL,
    sector_name             text NOT NULL,
    payment_terms_days      integer NOT NULL,
    created_date            date NOT NULL,
    activity_weight         numeric NOT NULL,
    is_habitual_late_payer  boolean NOT NULL DEFAULT false
);

CREATE TABLE generator.planted_error (
    planted_error_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    planted_id        text NOT NULL,
    raw_table         text NOT NULL,
    business_key      text NOT NULL,
    detail            text NOT NULL
);

-- Safety checks on the numbers we just loaded
DO $$
BEGIN
    IF abs((SELECT sum(central) FROM generator.parameter WHERE parameter_id LIKE 'SM%') - 1) > 0.0001 THEN
        RAISE EXCEPTION 'Stop: the sector shares SM1 to SM7 do not add up to 100 percent.';
    END IF;
    IF abs((SELECT sum(central) FROM generator.parameter WHERE parameter_id LIKE 'PT%') - 1) > 0.0001 THEN
        RAISE EXCEPTION 'Stop: the payment-term shares PT1 to PT3 do not add up to 100 percent.';
    END IF;
    IF (SELECT central FROM generator.parameter WHERE parameter_id = 'G10') > 15 THEN
        RAISE EXCEPTION 'Stop: this script has only 15 supplier name prefixes, but G10 asks for more.';
    END IF;
END $$;

-- Fixed seed, so a rerun on the same setup gives the same data
SELECT setseed((SELECT central FROM generator.parameter WHERE parameter_id = 'G03')::double precision);

-- Step 3a: decide how many customers go in each sector (running totals of the sector shares)
CREATE TEMP TABLE tmp_mix ON COMMIT DROP AS
SELECT sector_name, sum(share) OVER (ORDER BY ord) AS cum_share
FROM (
    SELECT s.ord, s.sector_name, p.central AS share
    FROM (VALUES (1, 'Hospitality', 'SM1'), (2, 'Corporate', 'SM2'), (3, 'Education', 'SM3'),
                 (4, 'Government', 'SM4'), (5, 'Non-profit', 'SM5'),
                 (6, 'Events and media', 'SM6'), (7, 'Healthcare', 'SM7')) AS s(ord, sector_name, pid)
    JOIN generator.parameter p ON p.parameter_id = s.pid
) m;

CREATE TEMP TABLE tmp_cust1 ON COMMIT DROP AS
SELECT i, sec.sector_name
FROM generate_series(1, (SELECT central::int FROM generator.parameter WHERE parameter_id = 'G06')) AS i
CROSS JOIN LATERAL (
    SELECT m.sector_name
    FROM tmp_mix m
    WHERE m.cum_share >= (i - 0.5) / (SELECT central FROM generator.parameter WHERE parameter_id = 'G06')
    ORDER BY m.cum_share
    LIMIT 1
) sec;

-- k = position inside the sector (used for the name); code_no = a shuffled number (used for the code)
CREATE TEMP TABLE tmp_cust2 ON COMMIT DROP AS
SELECT i,
       sector_name,
       row_number() OVER (PARTITION BY sector_name ORDER BY i) AS k,
       row_number() OVER (ORDER BY random())                   AS code_no
FROM tmp_cust1;

-- Step 3b: the hidden customer facts (answer key)
INSERT INTO generator.customer_profile
    (customer_code, customer_name, sector_name, payment_terms_days, created_date, activity_weight)
SELECT 'C' || lpad(x.code_no::text, 4, '0'),
       x.adj[(((x.k - 1) % 15) + 1)::int] || ' ' ||
       x.noun[((((x.k - 1) / 15) % cardinality(x.noun)) + 1)::int] ||
       CASE WHEN x.sector_name IN ('Hospitality', 'Corporate', 'Events and media', 'Healthcare')
            THEN ' Ltd' ELSE '' END,
       x.sector_name,
       CASE WHEN x.r < (SELECT central FROM generator.parameter WHERE parameter_id = 'PT1') THEN 14
            WHEN x.r < (SELECT central FROM generator.parameter WHERE parameter_id = 'PT1')
                     + (SELECT central FROM generator.parameter WHERE parameter_id = 'PT2') THEN 30
            ELSE 60 END,
       DATE '2019-01-01' + (random() * (DATE '2026-06-30' - DATE '2019-01-01'))::int,
       round((random() ^ 3 + 0.02)::numeric, 4)
FROM (
    SELECT t.*,
           random() AS r,
           ARRAY['Savanna', 'Lakeside', 'Highland', 'Coastal', 'Sunrise', 'Baobab', 'Acacia', 'Pearl',
                 'Unity', 'Heritage', 'Summit', 'Crescent', 'Horizon', 'Riverbend', 'Evergreen'] AS adj,
           CASE t.sector_name
                WHEN 'Hospitality'      THEN ARRAY['Hotels', 'Lodges', 'Resorts', 'Suites']
                WHEN 'Corporate'        THEN ARRAY['Holdings', 'Group', 'Logistics', 'Consulting', 'Capital']
                WHEN 'Education'        THEN ARRAY['Academy', 'College', 'Institute', 'Schools']
                WHEN 'Government'       THEN ARRAY['Public Works Agency', 'Development Authority', 'Regulatory Authority', 'Service Commission']
                WHEN 'Non-profit'       THEN ARRAY['Foundation', 'Trust', 'Relief Network', 'Community Fund']
                WHEN 'Events and media' THEN ARRAY['Events', 'Productions', 'Media', 'Studios']
                WHEN 'Healthcare'       THEN ARRAY['Medical Centre', 'Hospital', 'Clinic', 'Health Group']
                ELSE ARRAY['Group']
           END AS noun
    FROM tmp_cust2 t
) x;

-- A few customers are habitual late payers (used when payments are generated later)
UPDATE generator.customer_profile
SET is_habitual_late_payer = true
WHERE customer_code IN (
    SELECT customer_code
    FROM generator.customer_profile
    ORDER BY random()
    LIMIT (SELECT central::int FROM generator.parameter WHERE parameter_id = 'P07')
);

-- Pick customers for the planted mistakes: rn 1..D02 get a duplicate with a different spelling;
-- the next D05 customers get a blank sector.
CREATE TEMP TABLE tmp_pick ON COMMIT DROP AS
SELECT customer_code, row_number() OVER (ORDER BY random()) AS rn
FROM generator.customer_profile;

-- Step 3c: the original customers go into raw (some with a blank sector)
INSERT INTO raw.customer (customer_code, customer_name, sector_name, payment_terms_days, created_date)
SELECT p.customer_code,
       p.customer_name,
       CASE WHEN k.rn > d.d2 AND k.rn <= d.d2 + d.d5
            THEN CASE WHEN k.rn % 2 = 0 THEN NULL ELSE '' END
            ELSE p.sector_name END,
       p.payment_terms_days::text,
       p.created_date::text
FROM generator.customer_profile p
JOIN tmp_pick k ON k.customer_code = p.customer_code
CROSS JOIN (SELECT (SELECT central::int FROM generator.parameter WHERE parameter_id = 'D02') AS d2,
                   (SELECT central::int FROM generator.parameter WHERE parameter_id = 'D05') AS d5) d
ORDER BY p.customer_code;

-- Step 3d: the duplicates (same customer, new code, name spelled differently)
INSERT INTO raw.customer (customer_code, customer_name, sector_name, payment_terms_days, created_date)
SELECT 'C' || lpad(((SELECT central::int FROM generator.parameter WHERE parameter_id = 'G06') + k.rn)::text, 4, '0'),
       CASE ((k.rn - 1) % 6)
            WHEN 0 THEN upper(p.customer_name)
            WHEN 1 THEN lower(p.customer_name)
            WHEN 2 THEN replace(p.customer_name, ' ', '  ')
            WHEN 3 THEN p.customer_name || ' '
            WHEN 4 THEN ' ' || p.customer_name
            ELSE 'The ' || p.customer_name
       END,
       p.sector_name,
       p.payment_terms_days::text,
       p.created_date::text
FROM tmp_pick k
JOIN generator.customer_profile p ON p.customer_code = k.customer_code
WHERE k.rn <= (SELECT central::int FROM generator.parameter WHERE parameter_id = 'D02')
ORDER BY k.rn;

-- Step 3e: write every planted mistake into the answer key
INSERT INTO generator.planted_error (planted_id, raw_table, business_key, detail)
SELECT 'X02', 'raw.customer',
       'C' || lpad(((SELECT central::int FROM generator.parameter WHERE parameter_id = 'G06') + k.rn)::text, 4, '0'),
       'Duplicate of ' || k.customer_code || ' (name spelled differently)'
FROM tmp_pick k
WHERE k.rn <= (SELECT central::int FROM generator.parameter WHERE parameter_id = 'D02')
UNION ALL
SELECT 'X05', 'raw.customer', k.customer_code, 'Sector left blank or empty'
FROM tmp_pick k
WHERE k.rn >  (SELECT central::int FROM generator.parameter WHERE parameter_id = 'D02')
  AND k.rn <= (SELECT central::int FROM generator.parameter WHERE parameter_id = 'D02')
            + (SELECT central::int FROM generator.parameter WHERE parameter_id = 'D05')
UNION ALL
SELECT 'X08', 'raw.payment', customer_code, 'Habitual late payer (used when payments are generated)'
FROM generator.customer_profile
WHERE is_habitual_late_payer;

-- Step 3f: suppliers
INSERT INTO raw.supplier (supplier_code, supplier_name, country)
SELECT 'S' || lpad(i::text, 3, '0'),
       (ARRAY['Northwind', 'Vertex', 'Aurora', 'Kestrel', 'Orion', 'Zenith', 'Nimbus', 'Quantum',
              'Meridian', 'Solstice', 'Vanguard', 'Lumen', 'Atlas', 'Helix', 'Cobalt'])[i]
         || ' ' || (ARRAY['Audio', 'Visual', 'Lighting', 'Electronics', 'Systems'])[((i - 1) % 5) + 1],
       (ARRAY['China', 'Germany', 'USA', 'Japan', 'Kenya', 'UAE', 'South Africa', 'UK'])[((i - 1) % 8) + 1]
FROM generate_series(1, (SELECT central::int FROM generator.parameter WHERE parameter_id = 'G10')) AS i;

COMMIT;

-- Step 4: the check. One result table. Every row should say PASS.
SELECT what_we_check, expected, actual,
       CASE WHEN expected = actual THEN 'PASS' ELSE 'FAIL' END AS result
FROM (
    SELECT 1 AS n, 'Numbers copied from the register' AS what_we_check, '54' AS expected,
           (SELECT count(*) FROM generator.parameter)::text AS actual
    UNION ALL
    SELECT 2, 'Customer rows in raw (customers + duplicates)',
           ((SELECT central::int FROM generator.parameter WHERE parameter_id = 'G06')
          + (SELECT central::int FROM generator.parameter WHERE parameter_id = 'D02'))::text,
           (SELECT count(*) FROM raw.customer)::text
    UNION ALL
    SELECT 3, 'Supplier rows in raw',
           (SELECT central::int FROM generator.parameter WHERE parameter_id = 'G10')::text,
           (SELECT count(*) FROM raw.supplier)::text
    UNION ALL
    SELECT 4, 'Customers with a blank or missing sector',
           (SELECT central::int FROM generator.parameter WHERE parameter_id = 'D05')::text,
           (SELECT count(*) FROM raw.customer WHERE sector_name IS NULL OR btrim(sector_name) = '')::text
    UNION ALL
    SELECT 5, 'Customer rows that are name-variant duplicates (2 per pair)',
           (2 * (SELECT central::int FROM generator.parameter WHERE parameter_id = 'D02'))::text,
           (SELECT coalesce(sum(c), 0)
              FROM (SELECT count(*) AS c
                      FROM raw.customer
                     GROUP BY regexp_replace(regexp_replace(lower(btrim(customer_name)), '^the ', ''), '\s+', ' ', 'g')
                    HAVING count(*) > 1) g)::text
    UNION ALL
    SELECT 6, 'Customer codes used twice (should be none)', '0',
           (SELECT count(*) - count(DISTINCT customer_code) FROM raw.customer)::text
    UNION ALL
    SELECT 7, 'Habitual late payers marked in the answer key',
           (SELECT central::int FROM generator.parameter WHERE parameter_id = 'P07')::text,
           (SELECT count(*) FROM generator.customer_profile WHERE is_habitual_late_payer)::text
    UNION ALL
    SELECT 8, 'Planted mistakes written in the answer key',
           ((SELECT central::int FROM generator.parameter WHERE parameter_id = 'D02')
          + (SELECT central::int FROM generator.parameter WHERE parameter_id = 'D05')
          + (SELECT central::int FROM generator.parameter WHERE parameter_id = 'P07'))::text,
           (SELECT count(*) FROM generator.planted_error)::text
) t
ORDER BY n;
