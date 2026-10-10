-- Mwangaza AV (synthetic case study)
-- STAGE 7 in one file: create fake products and rental assets in the landing area (raw).
-- Run it ONCE, in the mwangaza_av database, AFTER Stage 6. STATUS: written, not yet run.
--
-- What it does, in plain words:
--   1. Stops with an error if Stage 6 has not been run, or if products or assets already exist.
--   2. Adds three more numbers to the answer key area (generator) and the price bands from the register.
--   3. Creates 80 products and 120 rental assets in raw, priced inside the category bands.
--   4. Secretly marks, in the answer key:
--        - some products as dead stock: they will have no sales in the last 12 months (planted error X11)
--        - some assets as idle and repair-prone: used under 10 percent of the time (planted error X10)
--      Later stages use these marks when sales and bookings are generated.
--   5. Shows one result table at the end. Every row should say PASS.
--
-- Safe: one all-or-nothing block (BEGIN ... COMMIT). If a line fails, nothing from it is saved.
-- It deletes nothing that exists.
-- The numbers below are a copy of docs/assumptions_register.xlsx. If you change the Excel file,
-- this copy must be updated too.
-- All names are made up from word lists. Prices are placeholders, not Kenyan market prices.

BEGIN;

-- Step 1: safety checks
DO $$
BEGIN
    IF to_regclass('generator.parameter') IS NULL OR (SELECT count(*) FROM raw.supplier) = 0 THEN
        RAISE EXCEPTION 'Stop: Stage 6 has not been run yet. Nothing was changed.';
    END IF;
    IF (SELECT count(*) FROM raw.product) > 0 OR (SELECT count(*) FROM raw.asset) > 0 THEN
        RAISE EXCEPTION 'Stop: raw.product or raw.asset already has rows. Nothing was changed.';
    END IF;
    IF to_regclass('generator.product_profile') IS NOT NULL THEN
        RAISE EXCEPTION 'Stop: the Stage 7 answer-key tables already exist. Nothing was changed.';
    END IF;
END $$;

-- Step 2: more numbers from the register, and the price bands
INSERT INTO generator.parameter (parameter_id, parameter_name, low, central, high, unit) VALUES
    ('R08', 'Asset purchase cost as a multiple of its daily rate', 100, 200, 300, 'x'),
    ('R09', 'Share of the fleet retired', 0.03, 0.05, 0.08, '%'),
    ('R10', 'Share of the fleet in repair at the as-of date', 0.02, 0.03, 0.05, '%');

CREATE TABLE generator.price_band (
    item_type      text NOT NULL,
    category_name  text NOT NULL,
    low_price      numeric NOT NULL,
    high_price     numeric NOT NULL,
    PRIMARY KEY (item_type, category_name)
);
INSERT INTO generator.price_band (item_type, category_name, low_price, high_price) VALUES
    ('Product', 'Microphones', 6000, 120000),
    ('Product', 'Loudspeakers and amplifiers', 15000, 350000),
    ('Product', 'Mixers and processors', 40000, 600000),
    ('Product', 'Displays and projectors', 60000, 900000),
    ('Product', 'Video conferencing', 50000, 600000),
    ('Product', 'Cables and connectors', 2000, 20000),
    ('Product', 'Lighting fixtures', 10000, 250000),
    ('Product', 'Control and automation devices', 5000, 150000),
    ('Asset', 'Conference audio', 1500, 8000),
    ('Asset', 'Sound reinforcement', 5000, 40000),
    ('Asset', 'Projection and screens', 4000, 30000),
    ('Asset', 'Stage lighting', 3000, 25000),
    ('Asset', 'LED displays', 15000, 80000),
    ('Asset', 'Video and streaming', 6000, 45000);

CREATE TABLE generator.product_profile (
    sku                 text PRIMARY KEY,
    product_name        text NOT NULL,
    category_name       text NOT NULL,
    supplier_code       text NOT NULL,
    list_price_ex_vat   numeric(14,2) NOT NULL,
    standard_cost       numeric(14,2) NOT NULL,
    sales_weight        numeric NOT NULL,
    is_dead_stock       boolean NOT NULL DEFAULT false
);

CREATE TABLE generator.asset_profile (
    asset_tag           text PRIMARY KEY,
    asset_name          text NOT NULL,
    category_name       text NOT NULL,
    util_group          text NOT NULL,
    purchase_date       date NOT NULL,
    purchase_cost       numeric(14,2) NOT NULL,
    daily_rate_ex_vat   numeric(14,2) NOT NULL,
    status              text NOT NULL,
    retired_date        date,
    is_idle_planted     boolean NOT NULL DEFAULT false,
    is_repair_prone     boolean NOT NULL DEFAULT false
);

-- A different seed from Stage 6 (the register seed plus 0.1), so the two stages do not repeat the same numbers
SELECT setseed(((SELECT central FROM generator.parameter WHERE parameter_id = 'G03') + 0.1)::double precision);

-- Step 3a: products
CREATE TEMP TABLE tmp_prod ON COMMIT DROP AS
SELECT i,
       (ARRAY['Microphones', 'Loudspeakers and amplifiers', 'Mixers and processors', 'Displays and projectors',
              'Video conferencing', 'Cables and connectors', 'Lighting fixtures',
              'Control and automation devices'])[((i - 1) % 8) + 1] AS category_name,
       (1 + floor(random() * (SELECT central FROM generator.parameter WHERE parameter_id = 'G10')))::int AS supplier_no,
       random() AS r_price,
       random() AS r_margin1,
       random() AS r_margin2
FROM generate_series(1, (SELECT central::int FROM generator.parameter WHERE parameter_id = 'G09')) AS i;

INSERT INTO generator.product_profile
    (sku, product_name, category_name, supplier_code, list_price_ex_vat, standard_cost, sales_weight)
SELECT 'P' || lpad(t.i::text, 4, '0'),
       split_part(s.supplier_name, ' ', 1) || ' ' || (100 + t.i * 7)::text || ' ' ||
       CASE t.category_name
            WHEN 'Microphones' THEN (ARRAY['Handheld Microphone', 'Lapel Microphone', 'Gooseneck Conference Microphone', 'Wireless Microphone Kit', 'Boundary Microphone'])[t.type_no]
            WHEN 'Loudspeakers and amplifiers' THEN (ARRAY['Ceiling Speaker', 'Line Array Speaker', 'Powered Speaker', 'Power Amplifier', 'Subwoofer'])[t.type_no]
            WHEN 'Mixers and processors' THEN (ARRAY['Digital Mixer', 'Audio Processor', 'Matrix Mixer', 'Echo Canceller', 'Signal Router'])[t.type_no]
            WHEN 'Displays and projectors' THEN (ARRAY['Laser Projector', 'Commercial Display', 'Interactive Panel', 'Projection Screen', 'Video Wall Panel'])[t.type_no]
            WHEN 'Video conferencing' THEN (ARRAY['Conference Camera', 'Video Bar', 'Codec', 'Speakerphone', 'Room Controller'])[t.type_no]
            WHEN 'Cables and connectors' THEN (ARRAY['HDMI Cable', 'XLR Cable', 'Wall Plate', 'Cable Reel', 'Connector Pack'])[t.type_no]
            WHEN 'Lighting fixtures' THEN (ARRAY['LED Par Light', 'Moving Head Light', 'Stage Wash Light', 'Lighting Controller', 'Architectural Light'])[t.type_no]
            ELSE (ARRAY['Touch Panel', 'Control Processor', 'Occupancy Sensor', 'Relay Module', 'Keypad'])[t.type_no]
       END,
       t.category_name,
       s.supplier_code,
       t.price,
       round((t.price * (1 - t.margin))::numeric, 2),
       round((random() ^ 3 + 0.02)::numeric, 4)
FROM (
    SELECT p.i,
           p.category_name,
           p.supplier_no,
           (((p.i - 1) / 8) % 5) + 1 AS type_no,
           round(exp(ln(b.low_price) + (ln(b.high_price) - ln(b.low_price)) * p.r_price)::numeric, -2) AS price,
           ((SELECT low FROM generator.parameter WHERE parameter_id = 'M01')
            + ((SELECT high FROM generator.parameter WHERE parameter_id = 'M01')
               - (SELECT low FROM generator.parameter WHERE parameter_id = 'M01'))
              * (p.r_margin1 + p.r_margin2) / 2) AS margin
    FROM tmp_prod p
    JOIN generator.price_band b ON b.item_type = 'Product' AND b.category_name = p.category_name
) t
JOIN raw.supplier s ON s.supplier_code = 'S' || lpad(t.supplier_no::text, 3, '0');

-- Dead stock: these products will have no sales in the last 12 months (enforced when sales are generated)
UPDATE generator.product_profile
SET is_dead_stock = true
WHERE sku IN (
    SELECT sku FROM generator.product_profile
    ORDER BY random()
    LIMIT (SELECT central::int FROM generator.parameter WHERE parameter_id = 'S01')
);

INSERT INTO raw.product (sku, product_name, product_category_name, supplier_code,
                         list_price_ex_vat, standard_cost, is_active)
SELECT sku, product_name, category_name, supplier_code,
       list_price_ex_vat::text, standard_cost::text, 'true'
FROM generator.product_profile
ORDER BY sku;

-- Step 3b: rental assets
CREATE TEMP TABLE tmp_asset ON COMMIT DROP AS
SELECT i,
       (ARRAY['Conference audio', 'Sound reinforcement', 'Projection and screens', 'Stage lighting',
              'LED displays', 'Video and streaming'])[((i - 1) % 6) + 1] AS category_name,
       random() AS r_rate,
       random() AS r_mult1,
       random() AS r_mult2,
       random() AS r_buy,
       random() AS r_status,
       random() AS r_retire
FROM generate_series(1, (SELECT central::int FROM generator.parameter WHERE parameter_id = 'G11')) AS i;

WITH prm AS (
    SELECT (SELECT low     FROM generator.parameter WHERE parameter_id = 'R08') AS mult_low,
           (SELECT high    FROM generator.parameter WHERE parameter_id = 'R08') AS mult_high,
           (SELECT central FROM generator.parameter WHERE parameter_id = 'R09') AS retired_share,
           (SELECT central FROM generator.parameter WHERE parameter_id = 'R10') AS repair_share
),
base AS (
    SELECT t.i,
           t.category_name,
           (((t.i - 1) / 6) % 5) + 1 AS type_no,
           t.r_mult1, t.r_mult2, t.r_status, t.r_retire,
           DATE '2018-01-01' + (t.r_buy * (DATE '2026-03-31' - DATE '2018-01-01'))::int AS purchase_date,
           round(exp(ln(b.low_price) + (ln(b.high_price) - ln(b.low_price)) * t.r_rate)::numeric, -2) AS rate
    FROM tmp_asset t
    JOIN generator.price_band b ON b.item_type = 'Asset' AND b.category_name = t.category_name
),
st AS (
    SELECT base.*,
           CASE WHEN base.r_status < prm.retired_share AND base.purchase_date <= DATE '2025-06-30' THEN 'retired'
                WHEN base.r_status >= prm.retired_share AND base.r_status < prm.retired_share + prm.repair_share THEN 'in_repair'
                ELSE 'active' END AS status
    FROM base CROSS JOIN prm
)
INSERT INTO generator.asset_profile
    (asset_tag, asset_name, category_name, util_group, purchase_date, purchase_cost,
     daily_rate_ex_vat, status, retired_date)
SELECT 'A' || lpad(st.i::text, 4, '0'),
       CASE st.category_name
            WHEN 'Conference audio'        THEN (ARRAY['Gooseneck Delegate Microphone Unit', 'Wireless Conference Microphone', 'Conference Speaker', 'Table Mixer', 'Delegate Charging Case'])[st.type_no]
            WHEN 'Sound reinforcement'     THEN (ARRAY['Line Array Speaker', 'Powered Subwoofer', 'Stage Monitor', 'Digital Mixing Desk', 'Wireless Handheld Kit'])[st.type_no]
            WHEN 'Projection and screens'  THEN (ARRAY['Laser Projector 7000 lumen', 'Projector 5000 lumen', 'Fast-fold Screen', 'Tripod Screen', 'Presentation Switcher'])[st.type_no]
            WHEN 'Stage lighting'          THEN (ARRAY['LED Par Light', 'Moving Head Light', 'Lighting Console', 'Truss Section', 'Haze Machine'])[st.type_no]
            WHEN 'LED displays'            THEN (ARRAY['LED Wall Panel', 'LED Screen Processor', 'Large Display Stand', 'Video Wall Controller', 'Display Trolley'])[st.type_no]
            ELSE (ARRAY['PTZ Camera', 'Video Switcher', 'Streaming Encoder', 'Camera Tripod Kit', 'Confidence Monitor'])[st.type_no]
       END || ' #' || lpad((((st.i - 1) / 6) + 1)::text, 2, '0'),
       st.category_name,
       CASE WHEN st.category_name IN ('Sound reinforcement', 'Stage lighting', 'LED displays')
            THEN 'event' ELSE 'core' END,
       st.purchase_date,
       round((st.rate * (prm.mult_low + (prm.mult_high - prm.mult_low) * (st.r_mult1 + st.r_mult2) / 2))::numeric, 2),
       st.rate,
       st.status,
       CASE WHEN st.status = 'retired'
            THEN GREATEST(st.purchase_date + 365, DATE '2024-01-01')
                 + (st.r_retire * (DATE '2026-06-30' - GREATEST(st.purchase_date + 365, DATE '2024-01-01')))::int
       END
FROM st CROSS JOIN prm;

-- Idle assets: used under 10 percent of the time and expensive to repair (enforced when bookings are generated)
UPDATE generator.asset_profile
SET is_idle_planted = true, is_repair_prone = true
WHERE asset_tag IN (
    SELECT asset_tag FROM generator.asset_profile
    WHERE status = 'active'
    ORDER BY random()
    LIMIT (SELECT round(g.central * r.central)::int
           FROM generator.parameter g, generator.parameter r
           WHERE g.parameter_id = 'G11' AND r.parameter_id = 'R03')
);

INSERT INTO raw.asset (asset_tag, asset_name, asset_category_name, purchase_date, purchase_cost,
                       daily_rate_ex_vat, status, retired_date)
SELECT asset_tag, asset_name, category_name, purchase_date::text, purchase_cost::text,
       daily_rate_ex_vat::text, status, retired_date::text
FROM generator.asset_profile
ORDER BY asset_tag;

-- Step 3c: write the planted mistakes into the answer key
INSERT INTO generator.planted_error (planted_id, raw_table, business_key, detail)
SELECT 'X11', 'raw.product', sku, 'Dead stock: no sale in the last 12 months (enforced when sales are generated)'
FROM generator.product_profile WHERE is_dead_stock
UNION ALL
SELECT 'X10', 'raw.asset', asset_tag, 'Idle asset used under 10 percent of the time, with high repair cost (enforced when bookings are generated)'
FROM generator.asset_profile WHERE is_idle_planted;

COMMIT;

-- Step 4: the check. One result table. Every row should say PASS.
SELECT what_we_check, expected, actual,
       CASE WHEN expected = actual THEN 'PASS' ELSE 'FAIL' END AS result
FROM (
    SELECT 1 AS n, 'New register numbers copied (R08, R09, R10)' AS what_we_check, '3' AS expected,
           (SELECT count(*) FROM generator.parameter WHERE parameter_id IN ('R08', 'R09', 'R10'))::text AS actual
    UNION ALL
    SELECT 2, 'Price bands loaded (8 products + 6 assets)', '14',
           (SELECT count(*) FROM generator.price_band)::text
    UNION ALL
    SELECT 3, 'Products in raw',
           (SELECT central::int FROM generator.parameter WHERE parameter_id = 'G09')::text,
           (SELECT count(*) FROM raw.product)::text
    UNION ALL
    SELECT 4, 'Assets in raw',
           (SELECT central::int FROM generator.parameter WHERE parameter_id = 'G11')::text,
           (SELECT count(*) FROM raw.asset)::text
    UNION ALL
    SELECT 5, 'Products priced outside their category band (should be none)', '0',
           (SELECT count(*)
              FROM generator.product_profile pp
              JOIN generator.price_band b ON b.item_type = 'Product' AND b.category_name = pp.category_name
             WHERE pp.list_price_ex_vat < b.low_price OR pp.list_price_ex_vat > b.high_price)::text
    UNION ALL
    SELECT 6, 'Products with a margin outside the register range (should be none)', '0',
           (SELECT count(*)
              FROM generator.product_profile
             WHERE list_price_ex_vat > 0
               AND ((1 - standard_cost / list_price_ex_vat) < (SELECT low FROM generator.parameter WHERE parameter_id = 'M01') - 0.0005
                 OR (1 - standard_cost / list_price_ex_vat) > (SELECT high FROM generator.parameter WHERE parameter_id = 'M01') + 0.0005))::text
    UNION ALL
    SELECT 7, 'Asset daily rates outside their category band (should be none)', '0',
           (SELECT count(*)
              FROM generator.asset_profile ap
              JOIN generator.price_band b ON b.item_type = 'Asset' AND b.category_name = ap.category_name
             WHERE ap.daily_rate_ex_vat < b.low_price OR ap.daily_rate_ex_vat > b.high_price)::text
    UNION ALL
    SELECT 8, 'Product supplier codes that match no supplier (should be none)', '0',
           (SELECT count(*)
              FROM raw.product p
              LEFT JOIN raw.supplier s ON s.supplier_code = p.supplier_code
             WHERE s.supplier_code IS NULL)::text
    UNION ALL
    SELECT 9, 'Dead-stock products marked in the answer key',
           (SELECT central::int FROM generator.parameter WHERE parameter_id = 'S01')::text,
           (SELECT count(*) FROM generator.product_profile WHERE is_dead_stock)::text
    UNION ALL
    SELECT 10, 'Idle assets marked in the answer key (fleet size x idle share, rounded)',
           (SELECT round(g.central * r.central)::int
              FROM generator.parameter g, generator.parameter r
             WHERE g.parameter_id = 'G11' AND r.parameter_id = 'R03')::text,
           (SELECT count(*) FROM generator.asset_profile WHERE is_idle_planted)::text
    UNION ALL
    SELECT 11, 'Assets where "retired" and the retired date disagree (should be none)', '0',
           (SELECT count(*) FROM raw.asset WHERE (status = 'retired') <> (retired_date IS NOT NULL))::text
) t
ORDER BY n;
