-- Mwangaza AV (synthetic case study)
-- STAGE 8 in one file: fake projects-division quotes, jobs and job costs in the landing area (raw).
-- Run it ONCE, in the mwangaza_av database, AFTER Stage 7. STATUS: run on PostgreSQL 18.6; the project owner reports all 12 checks passed.
--
-- What it does, in plain words:
--   1. Stops with an error if Stage 7 has not been run, or if quotes, jobs or job costs already exist.
--   2. Creates about 267 projects quotes spread over 3 years. Some are won, some lost, some expire,
--      and the newest are still open.
--   3. Every won quote becomes a job. Each job gets cost lines (equipment, labour, subcontractor, transport).
--   4. Plants three problems on purpose, and records them in the answer key:
--        X06  programming and commissioning labour overruns its quote on two job types
--        X07  one job type (Auditorium and hall fit-out) loses money on average
--        X12  quotes that take more than 45 days to decide are won less often
--      It also makes some quotes and jobs use the DUPLICATE customer codes from Stage 6.
--   5. Shows one result table at the end. Every row should say PASS.
--
-- Safe: one all-or-nothing block (BEGIN ... COMMIT). If a line fails, nothing from it is saved.
-- It deletes nothing that exists.
-- The numbers below are a copy of docs/assumptions_register.xlsx. If you change the Excel file,
-- this copy must be updated too.
-- Dates: history runs 2023-10-01 to 2026-09-30. The "as-of" date is 2026-09-30 (register rows G01 and G02).
-- Revenue of a job is its quoted price (no extra charges or discounts are modelled).

BEGIN;

-- Step 1: safety checks
DO $$
BEGIN
    IF to_regclass('generator.product_profile') IS NULL THEN
        RAISE EXCEPTION 'Stop: Stage 7 has not been run yet. Nothing was changed.';
    END IF;
    IF (SELECT count(*) FROM raw.quote) > 0 OR (SELECT count(*) FROM raw.job) > 0
       OR (SELECT count(*) FROM raw.job_cost_line) > 0 THEN
        RAISE EXCEPTION 'Stop: raw.quote, raw.job or raw.job_cost_line already has rows. Nothing was changed.';
    END IF;
    IF to_regclass('generator.quote_profile') IS NOT NULL THEN
        RAISE EXCEPTION 'Stop: the Stage 8 answer-key tables already exist. Nothing was changed.';
    END IF;
END $$;

-- Step 2: more numbers from the register
INSERT INTO generator.parameter (parameter_id, parameter_name, low, central, high, unit) VALUES
    ('C06', 'Share of non-won quotes that expire with no answer', 0.1, 0.2, 0.3, '%'),
    ('OF1', 'Share of quotes and jobs handled by the Nairobi office (rest: Mombasa)', 0.6, 0.7, 0.8, '%'),
    ('D06', 'Share of a duplicated customer''s records that use the duplicate code', 0.2, 0.3, 0.5, '%'),
    ('M10', 'Cost noise on equipment, subcontractor and transport', -0.05, 0, 0.05, '%'),
    ('CM1', 'Share of a job''s quoted cost: Equipment', NULL, 0.35, NULL, '%'),
    ('CM2', 'Share of a job''s quoted cost: Installation labour', NULL, 0.28, NULL, '%'),
    ('CM3', 'Share of a job''s quoted cost: Programming and commissioning labour', NULL, 0.18, NULL, '%'),
    ('CM4', 'Share of a job''s quoted cost: Subcontractor', NULL, 0.12, NULL, '%'),
    ('CM5', 'Share of a job''s quoted cost: Transport and logistics', NULL, 0.07, NULL, '%'),
    ('L01', 'Installation labour rate (KES per hour)', 1500, 2500, 4000, 'KES'),
    ('L02', 'Programming and commissioning labour rate (KES per hour)', 2500, 3500, 6000, 'KES');

DO $$
BEGIN
    IF abs((SELECT sum(central) FROM generator.parameter WHERE parameter_id LIKE 'CM%') - 1) > 0.0001 THEN
        RAISE EXCEPTION 'Stop: the cost shares CM1 to CM5 do not add up to 100 percent.';
    END IF;
END $$;

-- The answer-key tables for quotes and jobs.
-- The r_ columns are the random numbers drawn for each quote. They are kept so that later steps
-- (job timing, cost overruns) use the same draw and nothing has to be joined back by guesswork.
CREATE TABLE generator.quote_profile (
    quote_number       text PRIMARY KEY,
    division           text NOT NULL,
    customer_code      text NOT NULL,   -- the real customer (never the duplicate code)
    raw_customer_code  text NOT NULL,   -- the code written into raw (may be the duplicate code)
    office_name        text NOT NULL,
    job_type_name      text,
    quote_date         date NOT NULL,
    lag_days           integer NOT NULL,
    decision_date      date,
    status             text NOT NULL,
    quoted_price       numeric(14,2) NOT NULL,
    quoted_cost        numeric(14,2) NOT NULL,
    r_start            double precision,
    r_dur              double precision,
    r_labi             double precision,
    r_labc             double precision,
    r_nl               double precision,
    r_tm               double precision
);

CREATE TABLE generator.job_profile (
    job_number         text PRIMARY KEY,
    quote_number       text NOT NULL,
    customer_code      text NOT NULL,
    raw_customer_code  text NOT NULL,
    office_name        text NOT NULL,
    job_type_name      text NOT NULL,
    start_date         date NOT NULL,
    planned_end_date   date NOT NULL,
    end_date           date,
    status             text NOT NULL,
    quoted_price       numeric(14,2) NOT NULL,
    quoted_cost        numeric(14,2) NOT NULL
);

-- A new seed for this stage (register seed plus 0.2)
SELECT setseed(((SELECT central FROM generator.parameter WHERE parameter_id = 'G03') + 0.2)::double precision);

-- The numbers this stage needs, in one row
CREATE TEMP TABLE tmp_prm ON COMMIT DROP AS
SELECT
    DATE '2023-10-01' AS hist_start,
    DATE '2026-09-30' AS asof,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'G08') AS g08,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'C01') AS c01,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'C05') AS c05,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'C06') AS c06,
    (SELECT low  FROM generator.parameter WHERE parameter_id = 'C04') AS lag_low,
    (SELECT high FROM generator.parameter WHERE parameter_id = 'C04') AS lag_high,
    (SELECT low  FROM generator.parameter WHERE parameter_id = 'M03') AS m03_low,
    (SELECT high FROM generator.parameter WHERE parameter_id = 'M03') AS m03_high,
    (SELECT low  FROM generator.parameter WHERE parameter_id = 'M04') AS m04_low,
    (SELECT high FROM generator.parameter WHERE parameter_id = 'M04') AS m04_high,
    (SELECT low  FROM generator.parameter WHERE parameter_id = 'M05') AS m05_low,
    (SELECT high FROM generator.parameter WHERE parameter_id = 'M05') AS m05_high,
    (SELECT low  FROM generator.parameter WHERE parameter_id = 'M06') AS m06_low,
    (SELECT high FROM generator.parameter WHERE parameter_id = 'M06') AS m06_high,
    (SELECT low  FROM generator.parameter WHERE parameter_id = 'M07') AS m07_low,
    (SELECT high FROM generator.parameter WHERE parameter_id = 'M07') AS m07_high,
    (SELECT low  FROM generator.parameter WHERE parameter_id = 'M10') AS m10_low,
    (SELECT high FROM generator.parameter WHERE parameter_id = 'M10') AS m10_high,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'CM1') AS cm1,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'CM2') AS cm2,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'CM3') AS cm3,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'CM4') AS cm4,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'CM5') AS cm5,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'L01') AS l01,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'L02') AS l02,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'OF1') AS of1,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'D06') AS d06;

-- Step 3a: one row of random numbers for each quote
CREATE TEMP TABLE tmp_q ON COMMIT DROP AS
SELECT i,
       p.hist_start + (random() * (p.asof - p.hist_start))::int AS quote_date,
       random() AS r_lag,   random() AS r_win,   random() AS r_exp,   random() AS r_cust,
       random() AS r_dup,   random() AS r_off,   random() AS r_type,  random() AS r_price,
       random() AS r_m1,    random() AS r_m2,    random() AS r_start, random() AS r_dur,
       random() AS r_labi,  random() AS r_labc,  random() AS r_nl,    random() AS r_tm
FROM tmp_prm p
CROSS JOIN LATERAL generate_series(1, round(p.g08 / p.c01)::int) AS i;

-- Which duplicate code belongs to which real customer (from the Stage 6 answer key)
CREATE TEMP TABLE tmp_dup ON COMMIT DROP AS
SELECT substring(detail from 'Duplicate of (C[0-9]+)') AS orig_code, business_key AS dup_code
FROM generator.planted_error
WHERE planted_id = 'X02';

-- Step 3b: how long each quote takes to decide, and whether it is won, lost, expired or still open.
-- Days to decide = low + (high - low) x (random number to the power 4): most are fast, a few are slow.
-- Chance of winning = the register win rate, minus 15 points for quotes that take over 45 days
-- (planted problem X12), plus a small lift so the overall win rate stays near the register value.
CREATE TEMP TABLE tmp_q2 ON COMMIT DROP AS
WITH a AS (
    SELECT q.*, (p.lag_low + (p.lag_high - p.lag_low) * power(q.r_lag, 4))::int AS lag_days
    FROM tmp_q q CROSS JOIN tmp_prm p
),
b AS (
    SELECT a.*,
           p.c01
             + (p.c05 / 100.0) * (1 - power((45 - p.lag_low) / (p.lag_high - p.lag_low), 0.25))
             - CASE WHEN a.lag_days > 45 THEN p.c05 / 100.0 ELSE 0 END AS p_win
    FROM a CROSS JOIN tmp_prm p
)
SELECT b.*,
       CASE WHEN b.quote_date + b.lag_days > p.asof THEN 'open'
            WHEN b.r_win < b.p_win THEN 'won'
            WHEN b.r_exp < p.c06 THEN 'expired'
            ELSE 'lost' END AS status
FROM b CROSS JOIN tmp_prm p;

-- Step 3c: customer, office, job type and money for each quote
CREATE TEMP TABLE tmp_q3 ON COMMIT DROP AS
SELECT q.*,
       pick.customer_code AS customer_code,
       CASE WHEN d.dup_code IS NOT NULL AND q.r_dup < p.d06 THEN d.dup_code ELSE pick.customer_code END AS raw_customer_code,
       CASE WHEN q.r_off < p.of1 THEN 'Nairobi' ELSE 'Mombasa' END AS office_name,
       jt.job_type_name,
       round(LEAST(p.m07_high::float8,
                   GREATEST(p.m07_low::float8,
                            exp(ln(p.m07_low) + (ln(p.m07_high) - ln(p.m07_low)) * power(q.r_price, 1.15)) * jt.factor
                   ))::numeric, -3) AS quoted_price,
       p.m03_low + (p.m03_high - p.m03_low) * (q.r_m1 + q.r_m2) / 2 AS quoted_margin
FROM tmp_q2 q
CROSS JOIN tmp_prm p
CROSS JOIN LATERAL (
    -- pick a customer, more likely if they are a big one, and only if they already existed on the quote date
    SELECT c.customer_code
    FROM (SELECT cp.customer_code,
                 sum(cp.activity_weight) OVER (ORDER BY cp.customer_code) AS cum,
                 sum(cp.activity_weight) OVER () AS tot
          FROM generator.customer_profile cp
          WHERE cp.created_date <= q.quote_date) c
    WHERE c.cum >= q.r_cust * c.tot
    ORDER BY c.cum
    LIMIT 1
) pick
LEFT JOIN tmp_dup d ON d.orig_code = pick.customer_code
CROSS JOIN LATERAL (
    SELECT (ARRAY['Conference room installation', 'Public address and background audio',
                  'Video wall and display installation', 'Control room installation',
                  'Auditorium and hall fit-out', 'Stage lighting installation',
                  'Smart office and automation', 'Maintenance and support contract'])[1 + floor(q.r_type * 8)::int] AS job_type_name,
           (ARRAY[0.6, 0.5, 1.0, 2.0, 2.5, 0.8, 1.0, 0.3]::float8[])[1 + floor(q.r_type * 8)::int] AS factor
) jt;

-- Step 3d: number the quotes, save them in the answer key, and write them to raw
INSERT INTO generator.quote_profile
    (quote_number, division, customer_code, raw_customer_code, office_name, job_type_name,
     quote_date, lag_days, decision_date, status, quoted_price, quoted_cost,
     r_start, r_dur, r_labi, r_labc, r_nl, r_tm)
SELECT 'QP-' || lpad(row_number() OVER (ORDER BY quote_date, i)::text, 5, '0'),
       'projects', customer_code, raw_customer_code, office_name, job_type_name,
       quote_date, lag_days,
       CASE WHEN status IN ('won', 'lost') THEN quote_date + lag_days END,
       status, quoted_price,
       round((quoted_price * (1 - quoted_margin))::numeric, 2),
       r_start, r_dur, r_labi, r_labc, r_nl, r_tm
FROM tmp_q3;

INSERT INTO raw.quote (quote_number, customer_code, office_name, division, quote_date, decision_date,
                       status, quoted_price_ex_vat, quoted_cost)
SELECT quote_number, raw_customer_code, office_name, division, quote_date::text, decision_date::text,
       status, quoted_price::text, quoted_cost::text
FROM generator.quote_profile
ORDER BY quote_number;

-- Step 4a: every won quote becomes a job. A job starts 0 to 30 days after the decision and lasts about
-- 7 to 72 days (longer for bigger jobs). A job not finished by the as-of date is in_progress.
INSERT INTO generator.job_profile
    (job_number, quote_number, customer_code, raw_customer_code, office_name, job_type_name,
     start_date, planned_end_date, end_date, status, quoted_price, quoted_cost)
SELECT 'J-' || lpad(row_number() OVER (ORDER BY j.start_date, j.quote_number)::text, 4, '0'),
       j.quote_number, j.customer_code, j.raw_customer_code, j.office_name, j.job_type_name,
       j.start_date, j.planned_end_date,
       CASE WHEN j.planned_end_date <= p.asof THEN j.planned_end_date END,
       CASE WHEN j.planned_end_date <= p.asof THEN 'completed' ELSE 'in_progress' END,
       j.quoted_price, j.quoted_cost
FROM (
    SELECT qp.quote_number, qp.customer_code, qp.raw_customer_code, qp.office_name, qp.job_type_name,
           qp.quoted_price, qp.quoted_cost,
           LEAST(qp.decision_date + (qp.r_start * 30)::int, p2.asof) AS start_date,
           LEAST(qp.decision_date + (qp.r_start * 30)::int, p2.asof)
             + 7
             + (45 * ln(qp.quoted_price / p2.m07_low) / ln(p2.m07_high / p2.m07_low))::int
             + (qp.r_dur * 20)::int AS planned_end_date
    FROM generator.quote_profile qp
    CROSS JOIN tmp_prm p2
    WHERE qp.status = 'won'
) j
CROSS JOIN tmp_prm p;

INSERT INTO raw.job (job_number, quote_number, customer_code, office_name, job_type_name,
                     start_date, end_date, status)
SELECT job_number, quote_number, raw_customer_code, office_name, job_type_name,
       start_date::text, end_date::text, status
FROM generator.job_profile
ORDER BY job_number;

-- Step 4b: the cost of each category on each job (quoted cost x category share x a multiplier).
--   labour multipliers: ordinary jobs vary a little (register M05); on the two commissioning-heavy
--   job types the commissioning labour overruns (M04, planted problem X06).
--   the loss-making job type (Auditorium and hall fit-out) has its non-labour costs raised
--   until its margin lands in the M06 range (planted problem X07).
CREATE TEMP TABLE tmp_jobcat ON COMMIT DROP AS
SELECT j.job_number, j.start_date, j.planned_end_date, c.cost_category_name, c.kind,
       round((j.quoted_cost * c.share * c.mult)::numeric, 2) AS amount,
       (c.min_lines + floor(random() * c.extra_lines))::int AS n_lines
FROM (
    SELECT jp.job_number, jp.start_date, jp.planned_end_date, jp.job_type_name, jp.quoted_price, jp.quoted_cost,
           1 + p.m05_low + (p.m05_high - p.m05_low) * qp.r_labi AS mult_inst,
           CASE WHEN jp.job_type_name IN ('Control room installation', 'Smart office and automation')
                THEN 1 + p.m04_low + (p.m04_high - p.m04_low) * qp.r_labc
                ELSE 1 + p.m05_low + (p.m05_high - p.m05_low) * qp.r_labc END AS mult_comm,
           CASE WHEN jp.job_type_name = 'Auditorium and hall fit-out'
                THEN (jp.quoted_price * (1 - (p.m06_low + (p.m06_high - p.m06_low) * qp.r_tm))
                      - jp.quoted_cost * (p.cm2 * (1 + p.m05_low + (p.m05_high - p.m05_low) * qp.r_labi)
                                        + p.cm3 * (1 + p.m05_low + (p.m05_high - p.m05_low) * qp.r_labc)))
                     / (jp.quoted_cost * (p.cm1 + p.cm4 + p.cm5))
                ELSE 1 + p.m10_low + (p.m10_high - p.m10_low) * qp.r_nl END AS mult_nl
    FROM generator.job_profile jp
    JOIN generator.quote_profile qp ON qp.quote_number = jp.quote_number
    CROSS JOIN tmp_prm p
) j
CROSS JOIN tmp_prm p
CROSS JOIN LATERAL (
    SELECT v.cost_category_name, v.kind, v.min_lines, v.extra_lines,
           CASE v.kind WHEN 'equipment' THEN p.cm1 WHEN 'inst' THEN p.cm2 WHEN 'comm' THEN p.cm3
                       WHEN 'sub' THEN p.cm4 ELSE p.cm5 END AS share,
           CASE v.kind WHEN 'inst' THEN j.mult_inst WHEN 'comm' THEN j.mult_comm ELSE j.mult_nl END AS mult
    FROM (VALUES ('Equipment', 'equipment', 1, 5),
                 ('Installation labour', 'inst', 1, 4),
                 ('Programming and commissioning labour', 'comm', 1, 3),
                 ('Subcontractor', 'sub', 1, 2),
                 ('Transport and logistics', 'transport', 1, 2)) AS v(cost_category_name, kind, min_lines, extra_lines)
) c;

-- Step 4c: split each category into 1 to 5 lines
CREATE TEMP TABLE tmp_lines ON COMMIT DROP AS
SELECT g.job_number, g.start_date, g.planned_end_date, g.cost_category_name, g.kind, g.k, g.amount, g.w,
       sum(g.w) OVER (PARTITION BY g.job_number, g.cost_category_name) AS w_tot,
       random() AS u,
       (1 + floor(random() * 5))::int AS q_rand
FROM (
    SELECT jc.job_number, jc.start_date, jc.planned_end_date, jc.cost_category_name, jc.kind, jc.amount,
           k, random() + 0.2 AS w
    FROM tmp_jobcat jc
    CROSS JOIN LATERAL generate_series(1, jc.n_lines) AS k
) g;

-- Step 4d: write the lines to raw. Labour lines are hours x a standard hourly rate (register L01, L02).
-- Lines dated after the as-of date are left out (the work has not happened yet).
INSERT INTO raw.job_cost_line (job_number, cost_category_name, cost_date, description, quantity, unit_cost, sku)
SELECT z.job_number, z.cost_category_name, z.cost_date::text, z.description,
       z.quantity::text, z.unit_cost::text, NULL
FROM (
    SELECT l.job_number, l.cost_category_name, l.k,
           l.start_date + (CASE WHEN l.kind = 'comm' THEN 0.5 + 0.5 * l.u ELSE power(l.u, 1.5) END
                           * (l.planned_end_date - l.start_date))::int AS cost_date,
           CASE l.kind WHEN 'equipment' THEN 'Equipment supply'
                       WHEN 'inst' THEN 'Site installation labour'
                       WHEN 'comm' THEN 'Programming and commissioning'
                       WHEN 'sub' THEN 'Subcontracted works'
                       ELSE 'Transport and logistics' END AS description,
           CASE l.kind
                WHEN 'inst' THEN GREATEST(0.5, round((l.amount * l.w / l.w_tot / p.l01)::numeric, 2))
                WHEN 'comm' THEN GREATEST(0.5, round((l.amount * l.w / l.w_tot / p.l02)::numeric, 2))
                WHEN 'transport' THEN 1
                ELSE l.q_rand END AS quantity,
           CASE l.kind
                WHEN 'inst' THEN p.l01
                WHEN 'comm' THEN p.l02
                WHEN 'transport' THEN round((l.amount * l.w / l.w_tot)::numeric, 2)
                ELSE round((l.amount * l.w / l.w_tot / l.q_rand)::numeric, 2) END AS unit_cost
    FROM tmp_lines l
    CROSS JOIN tmp_prm p
) z
CROSS JOIN tmp_prm p
WHERE z.cost_date <= p.asof
ORDER BY z.job_number, z.cost_category_name, z.k;

-- Step 5: write the planted problems into the answer key
INSERT INTO generator.planted_error (planted_id, raw_table, business_key, detail)
SELECT 'X06', 'raw.job_cost_line', v.jt, 'Commissioning labour costs more than quoted on this job type (register M04)'
FROM (VALUES ('Control room installation'), ('Smart office and automation')) AS v(jt)
UNION ALL
SELECT 'X07', 'raw.job', 'Auditorium and hall fit-out', 'This job type loses money on average (register M06)'
UNION ALL
SELECT 'X12', 'raw.quote', quote_number, 'Decision took more than 45 days, so the quote is won less often (register C05)'
FROM generator.quote_profile
WHERE lag_days > 45;

COMMIT;

-- Step 6: the check. One result table. Every row should say PASS.
SELECT what_we_check, expected, actual,
       CASE WHEN expected = actual THEN 'PASS' ELSE 'FAIL' END AS result
FROM (
    SELECT 1 AS n, 'New register numbers copied' AS what_we_check, '11' AS expected,
           (SELECT count(*) FROM generator.parameter
             WHERE parameter_id IN ('C06','OF1','D06','M10','CM1','CM2','CM3','CM4','CM5','L01','L02'))::text AS actual
    UNION ALL
    SELECT 2, 'Projects quotes in raw (jobs target divided by win rate, rounded)',
           (SELECT round(g.central / c.central)::int FROM generator.parameter g, generator.parameter c
             WHERE g.parameter_id = 'G08' AND c.parameter_id = 'C01')::text,
           (SELECT count(*) FROM raw.quote WHERE division = 'projects')::text
    UNION ALL
    SELECT 3, 'Won quotes fall inside the register range for jobs (G08 low to high)', 'yes',
           (SELECT CASE WHEN count(*) BETWEEN (SELECT low FROM generator.parameter WHERE parameter_id = 'G08')
                                          AND (SELECT high FROM generator.parameter WHERE parameter_id = 'G08')
                        THEN 'yes' ELSE 'no' END
              FROM raw.quote WHERE status = 'won')
    UNION ALL
    SELECT 4, 'Jobs in raw equal won quotes',
           (SELECT count(*) FROM raw.quote WHERE status = 'won')::text,
           (SELECT count(*) FROM raw.job)::text
    UNION ALL
    SELECT 5, 'Jobs whose quote number matches no quote (should be none)', '0',
           (SELECT count(*) FROM raw.job j LEFT JOIN raw.quote q ON q.quote_number = j.quote_number
             WHERE q.quote_number IS NULL)::text
    UNION ALL
    SELECT 6, 'Quotes where status and decision date disagree (should be none)', '0',
           (SELECT count(*) FROM raw.quote
             WHERE (status IN ('won', 'lost')) <> (decision_date IS NOT NULL))::text
    UNION ALL
    SELECT 7, 'Cost lines whose job is not in raw.job (should be none)', '0',
           (SELECT count(*) FROM raw.job_cost_line c LEFT JOIN raw.job j ON j.job_number = c.job_number
             WHERE j.job_number IS NULL)::text
    UNION ALL
    SELECT 8, 'Cost lines dated after the as-of date (should be none)', '0',
           (SELECT count(*) FROM raw.job_cost_line WHERE cost_date::date > DATE '2026-09-30')::text
    UNION ALL
    SELECT 9, 'Slow-decision quotes (over 45 days) logged in the answer key',
           (SELECT count(*) FROM generator.quote_profile WHERE lag_days > 45)::text,
           (SELECT count(*) FROM generator.planted_error WHERE planted_id = 'X12')::text
    UNION ALL
    SELECT 10, 'Labour cost as a share of quoted price (finished jobs) is inside register range M02', 'yes',
           (SELECT CASE WHEN s.share BETWEEN (SELECT low FROM generator.parameter WHERE parameter_id = 'M02')
                                         AND (SELECT high FROM generator.parameter WHERE parameter_id = 'M02')
                        THEN 'yes' ELSE 'no' END
              FROM (SELECT (SELECT sum(c.quantity::numeric * c.unit_cost::numeric)
                              FROM raw.job_cost_line c
                              JOIN generator.job_profile jp ON jp.job_number = c.job_number
                             WHERE jp.status = 'completed'
                               AND c.cost_category_name IN ('Installation labour', 'Programming and commissioning labour'))
                           / (SELECT sum(quoted_price) FROM generator.job_profile WHERE status = 'completed') AS share) s)
    UNION ALL
    SELECT 11, 'Auditorium and hall fit-out: average margin (finished jobs) is inside register range M06', 'yes',
           (SELECT CASE WHEN avg(m.margin) BETWEEN (SELECT low FROM generator.parameter WHERE parameter_id = 'M06') - 0.005
                                               AND (SELECT high FROM generator.parameter WHERE parameter_id = 'M06') + 0.005
                        THEN 'yes' ELSE 'no' END
              FROM (SELECT 1 - (sum(c.quantity::numeric * c.unit_cost::numeric) / jp.quoted_price) AS margin
                      FROM generator.job_profile jp
                      JOIN raw.job_cost_line c ON c.job_number = jp.job_number
                     WHERE jp.status = 'completed' AND jp.job_type_name = 'Auditorium and hall fit-out'
                     GROUP BY jp.job_number, jp.quoted_price) m)
    UNION ALL
    SELECT 12, 'Commissioning labour overrun on the two commissioning-heavy job types is inside register range M04', 'yes',
           (SELECT CASE WHEN avg(o.overrun) BETWEEN (SELECT low FROM generator.parameter WHERE parameter_id = 'M04') - 0.01
                                                AND (SELECT high FROM generator.parameter WHERE parameter_id = 'M04') + 0.01
                        THEN 'yes' ELSE 'no' END
              FROM (SELECT sum(c.quantity::numeric * c.unit_cost::numeric)
                           / (jp.quoted_cost * (SELECT central FROM generator.parameter WHERE parameter_id = 'CM3')) - 1 AS overrun
                      FROM generator.job_profile jp
                      JOIN raw.job_cost_line c ON c.job_number = jp.job_number
                     WHERE jp.status = 'completed'
                       AND jp.job_type_name IN ('Control room installation', 'Smart office and automation')
                       AND c.cost_category_name = 'Programming and commissioning labour'
                     GROUP BY jp.job_number, jp.quoted_cost) o)
) t
ORDER BY n;
