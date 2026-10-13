-- Mwangaza AV (synthetic case study)
-- STAGE 10 in one file: fake rental bookings, booked assets and repairs in the landing area (raw).
-- Run it ONCE, in the mwangaza_av database, AFTER Stage 9. STATUS: run on PostgreSQL 18.6; the project owner reports all 12 checks passed.
--
-- What it does, in plain words:
--   1. Stops with an error if Stage 9 has not been run, or if rental data already exists.
--   2. Gives every asset its own run of rentals along its life, sized so the asset is on hire for the
--      share of days set in the register (event kit about 40 percent, core fleet about 65 percent,
--      the idle assets under 10 percent).
--   3. Groups rentals of different assets that start the same day and last the same time into one booking,
--      and gives each booking a customer and an office.
--   4. Creates repairs: damage found when a rental ends (the asset is then out of service for a few days),
--      one routine service a year, and a long repair running on the assets marked in_repair.
--   5. Plants two problems on purpose, and records them in the answer key:
--        X09  15 assets are double-booked (a second booking falls inside an existing one)
--        X10  the idle assets are hired under 10 percent of the time and cost a lot to repair
--   6. Shows one result table at the end. Every row should say PASS.
--
-- Safe: one all-or-nothing block (BEGIN ... COMMIT). If a line fails, nothing from it is saved.
-- It deletes nothing that exists.
-- The numbers below are a copy of docs/assumptions_register.xlsx. If you change the Excel file,
-- this copy must be updated too.
-- Dates: history runs 2023-10-01 to 2026-09-30. The "as-of" date is 2026-09-30.
-- Every booking is completed and ends on or before the as-of date. Quotes for bookings come in Stage 11.
-- Constants used in the timeline maths: mean rental length 3.34 days; mean repair length 6 days.

BEGIN;

-- Step 1: safety checks
DO $$
BEGIN
    IF to_regclass('generator.sales_order_profile') IS NULL THEN
        RAISE EXCEPTION 'Stop: Stage 9 has not been run yet. Nothing was changed.';
    END IF;
    IF (SELECT count(*) FROM raw.rental_booking) > 0 OR (SELECT count(*) FROM raw.rental_booking_line) > 0
       OR (SELECT count(*) FROM raw.maintenance_event) > 0 THEN
        RAISE EXCEPTION 'Stop: rental bookings, lines or maintenance events already exist. Nothing was changed.';
    END IF;
    IF to_regclass('generator.asset_plan') IS NOT NULL THEN
        RAISE EXCEPTION 'Stop: the Stage 10 answer-key tables already exist. Nothing was changed.';
    END IF;
END $$;

-- Step 2: more numbers from the register
INSERT INTO generator.parameter (parameter_id, parameter_name, low, central, high, unit) VALUES
    ('I01', 'PLANTED: utilisation of the idle assets (share of available days on hire)', 0.02, 0.05, 0.08, '%'),
    ('R13', 'PLANTED: repair-prone assets have damage this many times more often', 1.5, 2, 3, 'x'),
    ('R14', 'PLANTED: repair-prone assets cost this many times more per repair', 2, 2.5, 4, 'x'),
    ('R15', 'Discount on rental rates (share off the rate card)', 0, 0.05, 0.15, '%');

CREATE TABLE generator.asset_plan (
    asset_tag         text PRIMARY KEY,
    util_group        text NOT NULL,
    is_idle_planted   boolean NOT NULL,
    is_repair_prone   boolean NOT NULL,
    available_from    date NOT NULL,
    available_to      date NOT NULL,
    target_util       double precision NOT NULL,
    target_oos_share  double precision NOT NULL
);

CREATE TABLE generator.rental_booking_profile (
    booking_number           text PRIMARY KEY,
    customer_code            text NOT NULL,   -- the real customer (never the duplicate code)
    raw_customer_code        text NOT NULL,   -- the code written into raw (may be the duplicate code)
    office_name              text NOT NULL,
    start_date               date NOT NULL,
    end_date                 date NOT NULL,
    revenue                  numeric(14,2) NOT NULL,
    is_double_booking_extra  boolean NOT NULL DEFAULT false
);

-- A new seed for this stage (register seed plus 0.4)
SELECT setseed(((SELECT central FROM generator.parameter WHERE parameter_id = 'G03') + 0.4)::double precision);

CREATE TEMP TABLE tmp_prm3 ON COMMIT DROP AS
SELECT
    DATE '2023-10-01' AS hist_start,
    DATE '2026-09-30' AS asof,
    (SELECT low  FROM generator.parameter WHERE parameter_id = 'R01') AS r01_low,
    (SELECT high FROM generator.parameter WHERE parameter_id = 'R01') AS r01_high,
    (SELECT low  FROM generator.parameter WHERE parameter_id = 'R02') AS r02_low,
    (SELECT high FROM generator.parameter WHERE parameter_id = 'R02') AS r02_high,
    (SELECT low  FROM generator.parameter WHERE parameter_id = 'I01') AS i01_low,
    (SELECT high FROM generator.parameter WHERE parameter_id = 'I01') AS i01_high,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'R04') AS r04,
    (SELECT low  FROM generator.parameter WHERE parameter_id = 'R05') AS r05_low,
    (SELECT high FROM generator.parameter WHERE parameter_id = 'R05') AS r05_high,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'R07') AS r07,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'R13') AS r13,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'R14') AS r14,
    (SELECT low  FROM generator.parameter WHERE parameter_id = 'R15') AS r15_low,
    (SELECT high FROM generator.parameter WHERE parameter_id = 'R15') AS r15_high,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'OF1') AS of1,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'D06') AS d06;

-- Which duplicate code belongs to which real customer (from the Stage 6 answer key)
CREATE TEMP TABLE tmp_dup ON COMMIT DROP AS
SELECT substring(detail from 'Duplicate of (C[0-9]+)') AS orig_code, business_key AS dup_code
FROM generator.planted_error
WHERE planted_id = 'X02';

-- Step 3a: when each asset can be rented, and its utilisation target.
-- An asset can be rented from the later of its purchase date and the start of history,
-- until the earlier of its retired date and the as-of date (assets in repair stop 21 days earlier).
CREATE TEMP TABLE tmp_av ON COMMIT DROP AS
WITH s0 AS (
    SELECT ap.asset_tag, ap.util_group, ap.is_idle_planted, ap.is_repair_prone, ap.status,
           ap.daily_rate_ex_vat, ap.purchase_cost,
           GREATEST(ap.purchase_date, p.hist_start) AS a0,
           CASE WHEN ap.status = 'in_repair' THEN p.asof - 21
                ELSE LEAST(COALESCE(ap.retired_date, p.asof), p.asof) END AS a1,
           CASE WHEN ap.is_idle_planted THEN p.i01_low + (p.i01_high - p.i01_low) * random()
                WHEN ap.util_group = 'event' THEN p.r01_low + (p.r01_high - p.r01_low) * random()
                ELSE p.r02_low + (p.r02_high - p.r02_low) * random() END::float8 AS u,
           random() AS r0
    FROM generator.asset_profile ap
    CROSS JOIN tmp_prm3 p
),
s1 AS (
    SELECT s0.*,
           (p.r04 * CASE WHEN s0.is_repair_prone THEN p.r13 ELSE 1 END)::float8 AS s
    FROM s0 CROSS JOIN tmp_prm3 p
)
SELECT s1.*,
       -- average quiet gap between rentals that makes the asset hit its target (3.34 = mean rental length)
       (3.34 * ((1 - s1.s) / s1.u - 1))::float8 AS g_mean,
       -- chance that a rental ends with damage (6 = mean repair length)
       LEAST(1.0, s1.s * 3.34 / (s1.u * 6.0))::float8 AS p_dmg,
       (ceil((s1.a1 - s1.a0 + 1) * s1.u / 3.34 * 1.5) + 10)::int AS kmax
FROM s1
WHERE s1.a1 - s1.a0 >= 30;

INSERT INTO generator.asset_plan
    (asset_tag, util_group, is_idle_planted, is_repair_prone, available_from, available_to, target_util, target_oos_share)
SELECT asset_tag, util_group, is_idle_planted, is_repair_prone, a0, a1, u, s FROM tmp_av;

-- Step 3b: a run of rentals for each asset. Each row has a rental length, maybe damage (repair days),
-- and a quiet gap. Running totals of those lengths give non-overlapping start dates.
CREATE TEMP TABLE tmp_tl ON COMMIT DROP AS
WITH gen AS (
    SELECT a.asset_tag, a.a0, a.a1, a.r0, a.g_mean, a.p_dmg, a.purchase_cost, a.is_repair_prone,
           a.daily_rate_ex_vat, k,
           random() AS r_d, random() AS r_dmg, random() AS r_o, random() AS r_g, random() AS r_c
    FROM tmp_av a
    CROSS JOIN LATERAL generate_series(1, a.kmax) AS k
),
calc AS (
    SELECT gen.*,
           CASE WHEN r_d < 0.20 THEN 1 WHEN r_d < 0.45 THEN 2 WHEN r_d < 0.65 THEN 3
                WHEN r_d < 0.77 THEN 4 WHEN r_d < 0.87 THEN 5 WHEN r_d < 0.95 THEN 7 ELSE 10 END AS d,
           (r_dmg < p_dmg) AS dmg,
           CASE WHEN r_dmg < p_dmg THEN 2 + floor(r_o * 9)::int ELSE 0 END AS oos,
           round(-ln(1 - r_g) * g_mean)::int AS gap,
           round(-ln(1 - r0) * g_mean)::int AS off
    FROM gen
),
cum AS (
    SELECT calc.*, calc.d + calc.oos + calc.gap AS c FROM calc
)
SELECT cum.*,
       a0 + off + (sum(c) OVER (PARTITION BY asset_tag ORDER BY k) - c)::int AS start_date
FROM cum;

-- Keep only rentals that fit inside the asset's available dates
CREATE TEMP TABLE tmp_per ON COMMIT DROP AS
SELECT asset_tag, k, start_date, d, start_date + d - 1 AS end_date, dmg, oos,
       purchase_cost, is_repair_prone, daily_rate_ex_vat, r_c
FROM tmp_tl
WHERE start_date >= a0 AND start_date + d - 1 <= a1;

-- Step 3c: rentals with the same start date and length become one booking
CREATE TEMP TABLE tmp_grp ON COMMIT DROP AS
SELECT g.start_date, g.d, g.start_date + g.d - 1 AS end_date,
       row_number() OVER (ORDER BY g.start_date, g.d) AS gno,
       random() AS r_cust, random() AS r_dup, random() AS r_off, random() AS r_disc
FROM (SELECT DISTINCT start_date, d FROM tmp_per) g;

-- Customer, office and discount for each booking
CREATE TEMP TABLE tmp_grp2 ON COMMIT DROP AS
SELECT g.*,
       'B-' || lpad(g.gno::text, 5, '0') AS booking_number,
       pick.customer_code,
       CASE WHEN d.dup_code IS NOT NULL AND g.r_dup < p.d06 THEN d.dup_code ELSE pick.customer_code END AS raw_customer_code,
       CASE WHEN g.r_off < p.of1 THEN 'Nairobi' ELSE 'Mombasa' END AS office_name,
       p.r15_low + (p.r15_high - p.r15_low) * power(g.r_disc, 2) AS discount
FROM tmp_grp g
CROSS JOIN tmp_prm3 p
CROSS JOIN LATERAL (
    SELECT c.customer_code
    FROM (SELECT cp.customer_code,
                 sum(cp.activity_weight) OVER (ORDER BY cp.customer_code) AS cum,
                 sum(cp.activity_weight) OVER () AS tot
          FROM generator.customer_profile cp
          WHERE cp.created_date <= g.start_date) c
    WHERE c.cum >= g.r_cust * c.tot
    ORDER BY c.cum
    LIMIT 1
) pick
LEFT JOIN tmp_dup d ON d.orig_code = pick.customer_code;

-- The lines of each booking (one per asset rental)
CREATE TEMP TABLE tmp_lines ON COMMIT DROP AS
SELECT g.booking_number, per.asset_tag, per.d, per.dmg, per.oos, per.end_date, per.purchase_cost,
       per.is_repair_prone, per.r_c,
       round((per.daily_rate_ex_vat * (1 - g.discount))::numeric, 2) AS daily_rate
FROM tmp_per per
JOIN tmp_grp2 g ON g.start_date = per.start_date AND g.d = per.d;

-- Step 4: planted problem X09. Pick rentals of normal assets that last 2 or more days and add a second,
-- one-day booking of the same asset on day 2 of the original rental. Each overlaps exactly one other rental.
CREATE TEMP TABLE tmp_dbl ON COMMIT DROP AS
SELECT x.*,
       random() AS r_cust, random() AS r_dup, random() AS r_off,
       row_number() OVER (ORDER BY x.start_date, x.asset_tag) AS rn
FROM (
    SELECT per.asset_tag, per.start_date, per.daily_rate_ex_vat, g.booking_number AS orig_booking
    FROM tmp_per per
    JOIN tmp_grp2 g ON g.start_date = per.start_date AND g.d = per.d
    JOIN generator.asset_plan ap ON ap.asset_tag = per.asset_tag
    CROSS JOIN tmp_prm3 p
    WHERE per.d >= 2 AND NOT ap.is_idle_planted AND per.end_date <= p.asof - 5
    ORDER BY random()
    LIMIT (SELECT central::int FROM generator.parameter WHERE parameter_id = 'R07')
) x;

CREATE TEMP TABLE tmp_dbl2 ON COMMIT DROP AS
SELECT b.*,
       'B-' || lpad(((SELECT max(gno) FROM tmp_grp2) + b.rn)::text, 5, '0') AS booking_number,
       b.start_date + 1 AS new_date,
       pick.customer_code,
       CASE WHEN d.dup_code IS NOT NULL AND b.r_dup < p.d06 THEN d.dup_code ELSE pick.customer_code END AS raw_customer_code,
       CASE WHEN b.r_off < p.of1 THEN 'Nairobi' ELSE 'Mombasa' END AS office_name
FROM tmp_dbl b
CROSS JOIN tmp_prm3 p
CROSS JOIN LATERAL (
    SELECT c.customer_code
    FROM (SELECT cp.customer_code,
                 sum(cp.activity_weight) OVER (ORDER BY cp.customer_code) AS cum,
                 sum(cp.activity_weight) OVER () AS tot
          FROM generator.customer_profile cp
          WHERE cp.created_date <= b.start_date) c
    WHERE c.cum >= b.r_cust * c.tot
    ORDER BY c.cum
    LIMIT 1
) pick
LEFT JOIN tmp_dup d ON d.orig_code = pick.customer_code;

-- Step 5a: bookings, lines and the booking answer key
INSERT INTO generator.rental_booking_profile
    (booking_number, customer_code, raw_customer_code, office_name, start_date, end_date, revenue, is_double_booking_extra)
SELECT g.booking_number, g.customer_code, g.raw_customer_code, g.office_name, g.start_date, g.end_date,
       sum(l.daily_rate * l.d), false
FROM tmp_grp2 g
JOIN tmp_lines l ON l.booking_number = g.booking_number
GROUP BY g.booking_number, g.customer_code, g.raw_customer_code, g.office_name, g.start_date, g.end_date
UNION ALL
SELECT x.booking_number, x.customer_code, x.raw_customer_code, x.office_name, x.new_date, x.new_date,
       x.daily_rate_ex_vat, true
FROM tmp_dbl2 x;

INSERT INTO raw.rental_booking (booking_number, quote_number, customer_code, office_name, start_date, end_date, status)
SELECT booking_number, NULL, raw_customer_code, office_name, start_date::text, end_date::text, 'completed'
FROM generator.rental_booking_profile
ORDER BY booking_number;

INSERT INTO raw.rental_booking_line (booking_number, asset_tag, daily_rate_ex_vat)
SELECT booking_number, asset_tag, daily_rate::text
FROM tmp_lines
UNION ALL
SELECT booking_number, asset_tag, daily_rate_ex_vat::text
FROM tmp_dbl2
ORDER BY 1, 2;

-- Step 5b: repairs and services
INSERT INTO raw.maintenance_event (asset_tag, event_date, event_type, cost_amount, days_out_of_service, booking_number)
-- damage found when a rental ends
SELECT l.asset_tag, l.end_date::text, 'damage_repair',
       round((l.purchase_cost * (p.r05_low + (p.r05_high - p.r05_low) * power(l.r_c, 2.7))
              * CASE WHEN l.is_repair_prone THEN p.r14 ELSE 1 END)::numeric, 2)::text,
       l.oos::text, l.booking_number
FROM tmp_lines l
CROSS JOIN tmp_prm3 p
WHERE l.dmg
UNION ALL
-- one routine service a year, no downtime
SELECT a.asset_tag, (a.a0 + 180 + 365 * j)::text, 'routine_service',
       round((a.purchase_cost * (0.005 + 0.01 * random()))::numeric, 2)::text,
       '0', NULL
FROM tmp_av a
CROSS JOIN LATERAL generate_series(0, 3) AS j
WHERE a.a0 + 180 + 365 * j <= a.a1
UNION ALL
-- a long repair running at the as-of date for assets in repair
SELECT a.asset_tag, (p.asof - 20)::text, 'damage_repair',
       round((a.purchase_cost * (p.r05_low + (p.r05_high - p.r05_low) * random()))::numeric, 2)::text,
       '30', NULL
FROM tmp_av a
CROSS JOIN tmp_prm3 p
WHERE a.status = 'in_repair'
ORDER BY 2, 1;

-- Step 6: write the planted problems into the answer key
INSERT INTO generator.planted_error (planted_id, raw_table, business_key, detail)
SELECT 'X09', 'raw.rental_booking_line', x.asset_tag,
       'Double-booked: ' || x.orig_booking || ' and ' || x.booking_number || ' overlap'
FROM tmp_dbl2 x;

COMMIT;

-- Step 7: the check. One result table. Every row should say PASS.
SELECT what_we_check, expected, actual,
       CASE WHEN expected = actual THEN 'PASS' ELSE 'FAIL' END AS result
FROM (
    SELECT 1 AS n, 'New register numbers copied' AS what_we_check, '4' AS expected,
           (SELECT count(*) FROM generator.parameter WHERE parameter_id IN ('I01', 'R13', 'R14', 'R15'))::text AS actual
    UNION ALL
    SELECT 2, 'Bookings without any line (should be none)', '0',
           (SELECT count(*) FROM raw.rental_booking b
              LEFT JOIN raw.rental_booking_line l ON l.booking_number = b.booking_number
             WHERE l.booking_number IS NULL)::text
    UNION ALL
    SELECT 3, 'Lines whose asset is not in raw.asset (should be none)', '0',
           (SELECT count(*) FROM raw.rental_booking_line l
              LEFT JOIN raw.asset a ON a.asset_tag = l.asset_tag
             WHERE a.asset_tag IS NULL)::text
    UNION ALL
    SELECT 4, 'Bookings that start before the asset was bought (should be none)', '0',
           (SELECT count(*) FROM raw.rental_booking_line l
              JOIN raw.rental_booking b ON b.booking_number = l.booking_number
              JOIN raw.asset a ON a.asset_tag = l.asset_tag
             WHERE b.start_date::date < a.purchase_date::date)::text
    UNION ALL
    SELECT 5, 'Bookings after the asset was retired (should be none)', '0',
           (SELECT count(*) FROM raw.rental_booking_line l
              JOIN raw.rental_booking b ON b.booking_number = l.booking_number
              JOIN raw.asset a ON a.asset_tag = l.asset_tag
             WHERE a.retired_date IS NOT NULL AND b.end_date::date > a.retired_date::date)::text
    UNION ALL
    SELECT 6, 'Bookings that end after the as-of date (should be none)', '0',
           (SELECT count(*) FROM raw.rental_booking WHERE end_date::date > DATE '2026-09-30')::text
    UNION ALL
    SELECT 7, 'Double-booked pairs found by an overlap search (planted: register R07)',
           (SELECT central::int FROM generator.parameter WHERE parameter_id = 'R07')::text,
           (SELECT count(*)
              FROM raw.rental_booking_line l1
              JOIN raw.rental_booking b1 ON b1.booking_number = l1.booking_number
              JOIN raw.rental_booking_line l2 ON l2.asset_tag = l1.asset_tag AND l2.raw_row_id > l1.raw_row_id
              JOIN raw.rental_booking b2 ON b2.booking_number = l2.booking_number
             WHERE b1.start_date::date <= b2.end_date::date AND b2.start_date::date <= b1.end_date::date)::text
    UNION ALL
    SELECT 8, 'Core-fleet utilisation (normal assets) is inside register range R02', 'yes',
           (SELECT CASE WHEN u BETWEEN (SELECT low FROM generator.parameter WHERE parameter_id = 'R02')
                                   AND (SELECT high FROM generator.parameter WHERE parameter_id = 'R02')
                        THEN 'yes' ELSE 'no' END
              FROM (SELECT (SELECT sum(b.end_date::date - b.start_date::date + 1)
                              FROM raw.rental_booking_line l
                              JOIN raw.rental_booking b ON b.booking_number = l.booking_number
                              JOIN generator.asset_plan ap ON ap.asset_tag = l.asset_tag
                              JOIN generator.rental_booking_profile bp ON bp.booking_number = b.booking_number
                             WHERE ap.util_group = 'core' AND NOT ap.is_idle_planted AND NOT bp.is_double_booking_extra)::numeric
                           / (SELECT sum(available_to - available_from + 1) FROM generator.asset_plan
                               WHERE util_group = 'core' AND NOT is_idle_planted) AS u) q)
    UNION ALL
    SELECT 9, 'Event-kit utilisation (normal assets) is inside register range R01', 'yes',
           (SELECT CASE WHEN u BETWEEN (SELECT low FROM generator.parameter WHERE parameter_id = 'R01')
                                   AND (SELECT high FROM generator.parameter WHERE parameter_id = 'R01')
                        THEN 'yes' ELSE 'no' END
              FROM (SELECT (SELECT sum(b.end_date::date - b.start_date::date + 1)
                              FROM raw.rental_booking_line l
                              JOIN raw.rental_booking b ON b.booking_number = l.booking_number
                              JOIN generator.asset_plan ap ON ap.asset_tag = l.asset_tag
                              JOIN generator.rental_booking_profile bp ON bp.booking_number = b.booking_number
                             WHERE ap.util_group = 'event' AND NOT ap.is_idle_planted AND NOT bp.is_double_booking_extra)::numeric
                           / (SELECT sum(available_to - available_from + 1) FROM generator.asset_plan
                               WHERE util_group = 'event' AND NOT is_idle_planted) AS u) q)
    UNION ALL
    SELECT 10, 'Idle assets hired 10 percent of the time or more (should be none)', '0',
           (SELECT count(*)
              FROM generator.asset_plan ap
             WHERE ap.is_idle_planted
               AND coalesce((SELECT sum(b.end_date::date - b.start_date::date + 1)
                               FROM raw.rental_booking_line l
                               JOIN raw.rental_booking b ON b.booking_number = l.booking_number
                              WHERE l.asset_tag = ap.asset_tag), 0)::numeric
                   / (ap.available_to - ap.available_from + 1) >= 0.10)::text
    UNION ALL
    SELECT 11, 'Time lost to damage repairs (share of available asset-days) is inside register range R04', 'yes',
           (SELECT CASE WHEN s BETWEEN (SELECT low FROM generator.parameter WHERE parameter_id = 'R04')
                                   AND (SELECT high FROM generator.parameter WHERE parameter_id = 'R04')
                        THEN 'yes' ELSE 'no' END
              FROM (SELECT (SELECT sum(days_out_of_service::int) FROM raw.maintenance_event
                             WHERE event_type = 'damage_repair' AND booking_number IS NOT NULL)::numeric
                           / (SELECT sum(available_to - available_from + 1) FROM generator.asset_plan) AS s) q)
    UNION ALL
    SELECT 12, 'Maintenance events that point to a booking that does not exist (should be none)', '0',
           (SELECT count(*) FROM raw.maintenance_event m
              LEFT JOIN raw.rental_booking b ON b.booking_number = m.booking_number
             WHERE m.booking_number IS NOT NULL AND b.booking_number IS NULL)::text
) t
ORDER BY n;
