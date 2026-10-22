-- Mwangaza AV (synthetic case study)
-- Stage 19: business questions answered in SQL, as 18 views in the analysis schema.
-- Run order: once, in the mwangaza_av database, after Stage 18. Status: not yet executed.
--
-- Purpose:
--   Each view answers one business question from the reporting layer (mart). The question, the decision it
--   supports, the technique used and the pitfall it avoids are documented in docs/analysis-questions.md.
--   The views are also the data source for the Power BI pages.
--
-- Conventions:
--   * Amounts are in KES before VAT unless the column name says otherwise. "million" and "thousand" are KES.
--   * Job margin uses finished jobs only (is_finished). Jobs in progress carry partial costs and billing.
--   * Win rate counts won quotes over closed quotes (won, lost or expired) unless the view says "decided".
--   * Q09 reads core because the mart has no booking numbers per asset-day; every other view reads the mart.
--
-- Safety: runs as a single transaction (BEGIN ... COMMIT). The script creates a new schema and views only and
-- does not modify any table.

BEGIN;

DO $$
BEGIN
    IF to_regclass('mart.fact_invoice') IS NULL THEN
        RAISE EXCEPTION 'Stop: the mart tables do not exist (run Stage 18 first). Nothing was changed.';
    END IF;
    IF to_regclass('analysis.q01_margin_by_job_type') IS NOT NULL THEN
        RAISE EXCEPTION 'Stop: the analysis views already exist. Nothing was changed.';
    END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS analysis;
COMMENT ON SCHEMA analysis IS 'Business questions answered as views over the mart. Synthetic data only.';

-- ===== Page 1: profitability and cash =====

-- Q01. Which job types drift furthest from their quoted margin?
-- Pitfall: an average of percentages is not the margin of the whole group, so both are shown.
CREATE VIEW analysis.q01_margin_by_job_type AS
SELECT dj.job_type_name,
       count(*) AS finished_jobs,
       round(sum(f.invoiced_ex_vat) / 1000000, 2) AS billed_million,
       round(avg(f.quoted_margin_pct), 1) AS avg_quoted_margin_pct,
       round(avg(f.gross_margin_pct), 1) AS avg_actual_margin_pct,
       round(100 * sum(f.gross_profit) / nullif(sum(f.invoiced_ex_vat), 0), 1) AS weighted_actual_margin_pct,
       round(avg(f.margin_variance_pts), 1) AS avg_variance_pts
FROM mart.fact_job_margin f
JOIN mart.dim_job dj ON dj.job_key = f.job_key
WHERE f.is_finished
GROUP BY dj.job_type_name
ORDER BY weighted_actual_margin_pct;

-- Q02. Which customer sectors drift furthest from their quoted margin?
CREATE VIEW analysis.q02_margin_by_sector AS
SELECT dc.sector_name,
       count(*) AS finished_jobs,
       round(sum(f.invoiced_ex_vat) / 1000000, 2) AS billed_million,
       round(avg(f.quoted_margin_pct), 1) AS avg_quoted_margin_pct,
       round(100 * sum(f.gross_profit) / nullif(sum(f.invoiced_ex_vat), 0), 1) AS weighted_actual_margin_pct,
       round(avg(f.margin_variance_pts), 1) AS avg_variance_pts
FROM mart.fact_job_margin f
JOIN mart.dim_customer dc ON dc.customer_key = f.customer_key
WHERE f.is_finished
GROUP BY dc.sector_name
ORDER BY weighted_actual_margin_pct;

-- Q03. How old is the unpaid balance at the as-of date, by division?
-- Technique: a window over the grouped totals gives each bucket's share of the whole.
CREATE VIEW analysis.q03_ageing_of_unpaid_invoices AS
SELECT dv.division_name, f.ageing_bucket,
       count(*) AS invoices,
       round(sum(f.outstanding_amount) / 1000000, 2) AS outstanding_million,
       round(100 * sum(f.outstanding_amount) / sum(sum(f.outstanding_amount)) OVER (), 1) AS share_of_outstanding_pct
FROM mart.fact_invoice f
JOIN mart.dim_division dv ON dv.division_key = f.division_key
WHERE f.outstanding_amount > 0.005
GROUP BY dv.division_name, f.ageing_bucket
ORDER BY dv.division_name,
         CASE f.ageing_bucket WHEN 'Not yet due' THEN 1 WHEN '1 to 30 days overdue' THEN 2
                              WHEN '31 to 60 days overdue' THEN 3 WHEN '61 to 90 days overdue' THEN 4 ELSE 5 END;

-- Q04. Which customers pay latest after the due date?
-- Days are weighted by the amount paid. Customers with fewer than 10 payments applied are left out.
CREATE VIEW analysis.q04_slowest_payers AS
SELECT dc.customer_code, dc.customer_name, dc.sector_name, dc.payment_terms_days,
       count(*) AS payments_applied,
       round(sum(a.allocated_amount * a.days_after_due) / sum(a.allocated_amount), 1) AS weighted_days_after_due,
       round(sum(a.allocated_amount) / 1000000, 2) AS paid_million
FROM mart.fact_payment_allocation a
JOIN mart.dim_customer dc ON dc.customer_key = a.customer_key
GROUP BY dc.customer_code, dc.customer_name, dc.sector_name, dc.payment_terms_days
HAVING count(*) >= 10
ORDER BY weighted_days_after_due DESC;

-- Q05. Is payment behaviour getting better or worse over time?
-- Technique: LAG compares each quarter with the one before.
CREATE VIEW analysis.q05_payment_speed_by_quarter AS
WITH q AS (
    SELECT d.year AS calendar_year, d.quarter AS calendar_quarter,
           count(*) AS payments_applied,
           round(sum(a.allocated_amount * a.days_after_due) / sum(a.allocated_amount), 1) AS wdays
    FROM mart.fact_payment_allocation a
    JOIN mart.dim_date d ON d.date_key = a.payment_date_key
    GROUP BY d.year, d.quarter
)
SELECT calendar_year, calendar_quarter, payments_applied,
       wdays AS weighted_days_after_due,
       wdays - lag(wdays) OVER (ORDER BY calendar_year, calendar_quarter) AS change_vs_previous_quarter
FROM q
ORDER BY calendar_year, calendar_quarter;

-- Q06. Where does the money go on each job type (share of actual cost by category), and how does it differ from all jobs?
CREATE VIEW analysis.q06_cost_mix_by_job_type AS
SELECT dj.job_type_name,
       count(*) AS finished_jobs,
       round(100 * sum(f.equipment_cost) / sum(f.actual_cost), 1) AS equipment_pct,
       round(100 * sum(f.installation_labour_cost) / sum(f.actual_cost), 1) AS installation_labour_pct,
       round(100 * sum(f.commissioning_labour_cost) / sum(f.actual_cost), 1) AS commissioning_labour_pct,
       round(100 * sum(f.subcontractor_cost) / sum(f.actual_cost), 1) AS subcontractor_pct,
       round(100 * sum(f.transport_cost) / sum(f.actual_cost), 1) AS transport_pct,
       round(100 * sum(f.commissioning_labour_cost) / sum(f.actual_cost)
             - 100 * sum(sum(f.commissioning_labour_cost)) OVER () / sum(sum(f.actual_cost)) OVER (), 1)
           AS commissioning_pts_vs_all_jobs
FROM mart.fact_job_margin f
JOIN mart.dim_job dj ON dj.job_key = f.job_key
WHERE f.is_finished
GROUP BY dj.job_type_name
ORDER BY commissioning_pts_vs_all_jobs DESC;

-- ===== Page 2: rental assets =====

-- Q07. How much of the time is each asset category on hire?
CREATE VIEW analysis.q07_utilisation_by_category AS
SELECT a.category_name,
       count(DISTINCT f.asset_key) AS assets,
       count(*) AS asset_days,
       sum(f.on_hire) AS days_on_hire,
       round(100.0 * sum(f.on_hire) / count(*), 1) AS time_utilisation_pct,
       round(100.0 * sum(f.out_of_service) / count(*), 1) AS out_of_service_pct,
       round(sum(f.rental_revenue) / 1000000, 1) AS revenue_million
FROM mart.fact_asset_day f
JOIN mart.dim_asset a ON a.asset_key = f.asset_key
GROUP BY a.category_name
ORDER BY time_utilisation_pct DESC;

-- Q08. Which assets are on hire less than 10 percent of the time, and what do they cost to repair?
-- Pitfall: revenue and repairs are summed in separate steps and joined by asset, so neither is multiplied.
CREATE VIEW analysis.q08_idle_assets_and_repair_cost AS
WITH u AS (
    SELECT f.asset_key, count(*) AS asset_days, sum(f.on_hire) AS on_hire_days, sum(f.rental_revenue) AS revenue
    FROM mart.fact_asset_day f
    GROUP BY f.asset_key
),
r AS (
    SELECT m.asset_key, sum(m.cost_amount) AS repair_cost,
           count(*) FILTER (WHERE m.event_type = 'damage_repair') AS damage_events
    FROM mart.fact_maintenance m
    GROUP BY m.asset_key
)
SELECT a.asset_tag, a.asset_name, a.category_name, u.asset_days,
       round(100.0 * u.on_hire_days / u.asset_days, 1) AS time_utilisation_pct,
       round(u.revenue, 0) AS rental_revenue,
       coalesce(r.repair_cost, 0) AS repair_and_service_cost,
       coalesce(r.damage_events, 0) AS damage_events,
       round(100.0 * coalesce(r.repair_cost, 0) / nullif(u.revenue, 0), 1) AS repair_cost_pct_of_revenue
FROM u
JOIN mart.dim_asset a ON a.asset_key = u.asset_key
LEFT JOIN r ON r.asset_key = u.asset_key
WHERE 100.0 * u.on_hire_days / u.asset_days < 10
ORDER BY time_utilisation_pct;

-- Q09. Which assets are booked twice on overlapping dates? (reads core)
-- Technique: a self-join of the booked-asset lines, comparing date ranges.
CREATE VIEW analysis.q09_double_booked_assets AS
SELECT a.asset_tag, a.asset_name,
       b1.booking_number AS first_booking, b1.start_date AS first_start, b1.end_date AS first_end,
       b2.booking_number AS second_booking, b2.start_date AS second_start, b2.end_date AS second_end,
       LEAST(b1.end_date, b2.end_date) - GREATEST(b1.start_date, b2.start_date) + 1 AS overlapping_days
FROM core.rental_booking_line l1
JOIN core.rental_booking b1 ON b1.rental_booking_id = l1.rental_booking_id
JOIN core.rental_booking_line l2 ON l2.asset_id = l1.asset_id AND l2.rental_booking_line_id > l1.rental_booking_line_id
JOIN core.rental_booking b2 ON b2.rental_booking_id = l2.rental_booking_id
JOIN core.asset a ON a.asset_id = l1.asset_id
WHERE b1.start_date <= b2.end_date AND b2.start_date <= b1.end_date
ORDER BY overlapping_days DESC, a.asset_tag;

-- Q10. What do repairs and services cost against rental revenue, by asset category?
CREATE VIEW analysis.q10_repair_economics_by_category AS
WITH rev AS (
    SELECT a.category_name, sum(f.rental_revenue) AS revenue
    FROM mart.fact_asset_day f
    JOIN mart.dim_asset a ON a.asset_key = f.asset_key
    GROUP BY a.category_name
),
rep AS (
    SELECT a.category_name,
           sum(m.cost_amount) FILTER (WHERE m.event_type = 'damage_repair') AS damage_cost,
           sum(m.cost_amount) FILTER (WHERE m.event_type = 'routine_service') AS service_cost,
           sum(m.days_out_of_service) AS days_out_of_service
    FROM mart.fact_maintenance m
    JOIN mart.dim_asset a ON a.asset_key = m.asset_key
    GROUP BY a.category_name
)
SELECT rev.category_name,
       round(rev.revenue / 1000000, 1) AS revenue_million,
       round(coalesce(rep.damage_cost, 0) / 1000000, 1) AS damage_repairs_million,
       round(coalesce(rep.service_cost, 0) / 1000000, 1) AS routine_service_million,
       coalesce(rep.days_out_of_service, 0) AS days_out_of_service,
       round(100 * (coalesce(rep.damage_cost, 0) + coalesce(rep.service_cost, 0)) / rev.revenue, 1) AS repair_and_service_pct_of_revenue
FROM rev
LEFT JOIN rep ON rep.category_name = rev.category_name
ORDER BY repair_and_service_pct_of_revenue DESC;

-- Q11. Which assets have the longest idle stretches between bookings? (top 25; reads core)
-- Technique: LEAD looks at the next booking of the same asset.
CREATE VIEW analysis.q11_longest_idle_gaps AS
WITH b AS (
    SELECT l.asset_id, rb.start_date, rb.end_date,
           lead(rb.start_date) OVER (PARTITION BY l.asset_id ORDER BY rb.start_date, rb.end_date) AS next_start
    FROM core.rental_booking_line l
    JOIN core.rental_booking rb ON rb.rental_booking_id = l.rental_booking_id
)
SELECT a.asset_tag, a.asset_name, c.asset_category_name,
       b.end_date AS booking_ends, b.next_start AS next_booking_starts,
       b.next_start - b.end_date - 1 AS idle_days
FROM b
JOIN core.asset a ON a.asset_id = b.asset_id
JOIN core.asset_category c ON c.asset_category_id = a.asset_category_id
WHERE b.next_start IS NOT NULL
ORDER BY idle_days DESC, a.asset_tag
LIMIT 25;

-- ===== Page 3: commercial and stock =====

-- Q12. How does the win rate change with quote size, by division?
CREATE VIEW analysis.q12_win_rate_by_division_and_size AS
SELECT x.division_name, x.price_band,
       count(*) AS closed_quotes,
       count(*) FILTER (WHERE x.is_won) AS won_quotes,
       round(100.0 * count(*) FILTER (WHERE x.is_won) / count(*), 1) AS win_rate_pct
FROM (
    SELECT dd.division_name, q.is_won,
           CASE WHEN q.quoted_price_ex_vat < 100000 THEN '1: under 100k'
                WHEN q.quoted_price_ex_vat < 500000 THEN '2: 100k to 500k'
                WHEN q.quoted_price_ex_vat < 2000000 THEN '3: 500k to 2m'
                ELSE '4: 2m and over' END AS price_band
    FROM mart.fact_quote q
    JOIN mart.dim_division dd ON dd.division_key = q.division_key
    WHERE q.is_closed
) x
GROUP BY x.division_name, x.price_band
ORDER BY x.division_name, x.price_band;

-- Q13. Do quotes that take longer to decide win less often? (won and lost quotes only)
CREATE VIEW analysis.q13_win_rate_by_decision_speed AS
SELECT x.decision_speed,
       count(*) AS decided_quotes,
       count(*) FILTER (WHERE x.is_won) AS won_quotes,
       round(100.0 * count(*) FILTER (WHERE x.is_won) / count(*), 1) AS win_rate_pct
FROM (
    SELECT q.is_won,
           CASE WHEN q.days_to_decide <= 7 THEN '1: 0 to 7 days'
                WHEN q.days_to_decide <= 14 THEN '2: 8 to 14 days'
                WHEN q.days_to_decide <= 30 THEN '3: 15 to 30 days'
                WHEN q.days_to_decide <= 45 THEN '4: 31 to 45 days'
                ELSE '5: over 45 days' END AS decision_speed
    FROM mart.fact_quote q
    WHERE q.status IN ('won', 'lost')
) x
GROUP BY x.decision_speed
ORDER BY x.decision_speed;

-- Q14. Which products have not sold for the longest time, and how much stock is tied up in them?
-- Products that never sold have no last sale date and are listed first.
CREATE VIEW analysis.q14_stock_without_recent_sales AS
WITH last_sale AS (
    SELECT l.product_key, max(d.full_date) AS last_sale_date
    FROM mart.fact_sales_line l
    JOIN mart.dim_date d ON d.date_key = l.order_date_key
    GROUP BY l.product_key
),
stock AS (
    SELECT product_key, sum(quantity_change) AS on_hand
    FROM mart.fact_stock_movement
    GROUP BY product_key
)
SELECT p.sku, p.product_name, p.category_name,
       ls.last_sale_date,
       ri.as_of_date - ls.last_sale_date AS days_since_last_sale,
       coalesce(s.on_hand, 0) AS stock_on_hand,
       round(coalesce(s.on_hand, 0) * p.standard_cost, 0) AS stock_value_at_cost
FROM mart.dim_product p
CROSS JOIN mart.report_info ri
LEFT JOIN last_sale ls ON ls.product_key = p.product_key
LEFT JOIN stock s ON s.product_key = p.product_key
ORDER BY days_since_last_sale DESC NULLS FIRST, stock_value_at_cost DESC;

-- Q15. How concentrated is billing among customers? (running share, largest first)
CREATE VIEW analysis.q15_revenue_concentration AS
WITH c AS (
    SELECT dc.customer_code, dc.customer_name, dc.sector_name, sum(f.amount_ex_vat) AS billed
    FROM mart.fact_invoice f
    JOIN mart.dim_customer dc ON dc.customer_key = f.customer_key
    GROUP BY dc.customer_code, dc.customer_name, dc.sector_name
),
r AS (
    SELECT c.*,
           row_number() OVER (ORDER BY c.billed DESC, c.customer_code) AS rank_no,
           sum(c.billed) OVER (ORDER BY c.billed DESC, c.customer_code
                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cum_billed,
           sum(c.billed) OVER () AS total_billed
    FROM c
)
SELECT rank_no, customer_code, customer_name, sector_name,
       round(billed / 1000000, 2) AS billed_million,
       round(100 * billed / total_billed, 1) AS share_pct,
       round(100 * cum_billed / total_billed, 1) AS cumulative_share_pct
FROM r
ORDER BY rank_no;

-- Q16. How long do quotes take to be decided, by division? (won and lost quotes)
CREATE VIEW analysis.q16_decision_time_by_division AS
SELECT dd.division_name,
       count(*) AS decided_quotes,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY q.days_to_decide))::numeric, 1) AS median_days,
       round((percentile_cont(0.9) WITHIN GROUP (ORDER BY q.days_to_decide))::numeric, 1) AS p90_days,
       max(q.days_to_decide) AS longest_days
FROM mart.fact_quote q
JOIN mart.dim_division dd ON dd.division_key = q.division_key
WHERE q.status IN ('won', 'lost')
GROUP BY dd.division_name
ORDER BY dd.division_name;

-- ===== Across divisions =====

-- Q17. What is each customer worth across the three divisions (billing before VAT)?
-- Revenue only: costs exist for projects and products but not for rentals, so margin is not compared here.
CREATE VIEW analysis.q17_customer_value_across_divisions AS
SELECT dc.customer_code, dc.customer_name, dc.sector_name,
       round(coalesce(sum(f.amount_ex_vat) FILTER (WHERE dv.division_code = 'projects'), 0) / 1000, 0) AS projects_thousand,
       round(coalesce(sum(f.amount_ex_vat) FILTER (WHERE dv.division_code = 'products'), 0) / 1000, 0) AS products_thousand,
       round(coalesce(sum(f.amount_ex_vat) FILTER (WHERE dv.division_code = 'rentals'), 0) / 1000, 0) AS rentals_thousand,
       round(sum(f.amount_ex_vat) / 1000, 0) AS total_thousand,
       count(DISTINCT f.division_key) AS divisions_used
FROM mart.fact_invoice f
JOIN mart.dim_customer dc ON dc.customer_key = f.customer_key
JOIN mart.dim_division dv ON dv.division_key = f.division_key
GROUP BY dc.customer_code, dc.customer_name, dc.sector_name
ORDER BY sum(f.amount_ex_vat) DESC;

-- Q18. Which customers rent equipment but have never been billed for a project?
-- Technique: NOT EXISTS (an anti-join), which stays correct when empty values are present.
CREATE VIEW analysis.q18_rent_only_customers AS
SELECT dc.customer_code, dc.customer_name, dc.sector_name,
       count(*) AS rental_invoices,
       round(sum(f.amount_ex_vat) / 1000, 0) AS rentals_thousand
FROM mart.fact_invoice f
JOIN mart.dim_customer dc ON dc.customer_key = f.customer_key
WHERE f.division_key = 3
  AND NOT EXISTS (SELECT 1 FROM mart.fact_invoice p WHERE p.customer_key = f.customer_key AND p.division_key = 1)
GROUP BY dc.customer_code, dc.customer_name, dc.sector_name
ORDER BY sum(f.amount_ex_vat) DESC;

COMMIT;

-- Checks: each answer is tested against an independent count, total or the answer key.
-- One result table; every row should read PASS.
SELECT what_we_check, expected, actual,
       CASE WHEN expected = actual THEN 'PASS' ELSE 'FAIL' END AS result
FROM (
    SELECT 1 AS n, 'Views in the analysis schema' AS what_we_check, '18' AS expected,
           (SELECT count(*) FROM information_schema.views WHERE table_schema = 'analysis')::text AS actual
    UNION ALL
    SELECT 2, 'Q01 finished jobs equal finished jobs in core',
           (SELECT count(*) FROM core.job WHERE status = 'completed')::text,
           (SELECT sum(finished_jobs) FROM analysis.q01_margin_by_job_type)::text
    UNION ALL
    SELECT 3, 'Q02 finished jobs equal finished jobs in core',
           (SELECT count(*) FROM core.job WHERE status = 'completed')::text,
           (SELECT sum(finished_jobs) FROM analysis.q02_margin_by_sector)::text
    UNION ALL
    SELECT 4, 'Q03 unpaid invoices equal invoices with a balance in the mart',
           (SELECT count(*) FROM mart.fact_invoice WHERE outstanding_amount > 0.005)::text,
           (SELECT sum(invoices) FROM analysis.q03_ageing_of_unpaid_invoices)::text
    UNION ALL
    SELECT 5, 'Q03 shares add up to 100 percent (within 1)', 'yes',
           (SELECT CASE WHEN abs(sum(share_of_outstanding_pct) - 100) < 1 THEN 'yes' ELSE 'no' END
              FROM analysis.q03_ageing_of_unpaid_invoices)
    UNION ALL
    SELECT 6, 'Q05 payments equal the payment allocations in the mart',
           (SELECT count(*) FROM mart.fact_payment_allocation)::text,
           (SELECT sum(payments_applied) FROM analysis.q05_payment_speed_by_quarter)::text
    UNION ALL
    SELECT 7, 'Q06 job types whose cost shares do not add up to 100 percent (should be none)', '0',
           (SELECT count(*) FROM analysis.q06_cost_mix_by_job_type
             WHERE abs(equipment_pct + installation_labour_pct + commissioning_labour_pct
                       + subcontractor_pct + transport_pct - 100) > 0.5)::text
    UNION ALL
    SELECT 8, 'Q07 asset-days equal the rows of the asset-day fact',
           (SELECT count(*) FROM mart.fact_asset_day)::text,
           (SELECT sum(asset_days) FROM analysis.q07_utilisation_by_category)::text
    UNION ALL
    SELECT 9, 'Answer key: planted idle assets missing from Q08 (should be none)', '0',
           (SELECT count(*) FROM generator.asset_profile ap
             WHERE ap.is_idle_planted
               AND NOT EXISTS (SELECT 1 FROM analysis.q08_idle_assets_and_repair_cost q WHERE q.asset_tag = ap.asset_tag))::text
    UNION ALL
    SELECT 10, 'Q09 double-booked pairs (planted: register R07)',
           (SELECT central::int FROM generator.parameter WHERE parameter_id = 'R07')::text,
           (SELECT count(*) FROM analysis.q09_double_booked_assets)::text
    UNION ALL
    SELECT 11, 'Answer key: planted double-booked assets missing from Q09 (should be none)', '0',
           (SELECT count(*) FROM generator.planted_error pe
             WHERE pe.planted_id = 'X09'
               AND NOT EXISTS (SELECT 1 FROM analysis.q09_double_booked_assets q WHERE q.asset_tag = pe.business_key))::text
    UNION ALL
    SELECT 12, 'Q12 closed quotes equal closed quotes in the mart',
           (SELECT count(*) FROM mart.fact_quote WHERE is_closed)::text,
           (SELECT sum(closed_quotes) FROM analysis.q12_win_rate_by_division_and_size)::text
    UNION ALL
    SELECT 13, 'Q13 decided quotes equal won and lost quotes in the mart',
           (SELECT count(*) FROM mart.fact_quote WHERE status IN ('won', 'lost'))::text,
           (SELECT sum(decided_quotes) FROM analysis.q13_win_rate_by_decision_speed)::text
    UNION ALL
    SELECT 14, 'Q14 lists every product',
           (SELECT count(*) FROM mart.dim_product)::text,
           (SELECT count(*) FROM analysis.q14_stock_without_recent_sales)::text
    UNION ALL
    SELECT 15, 'Answer key: planted dead-stock products that do not show a year without a sale in Q14 (should be none)', '0',
           (SELECT count(*) FROM generator.product_profile pp
             WHERE pp.is_dead_stock
               AND NOT EXISTS (SELECT 1 FROM analysis.q14_stock_without_recent_sales q
                                WHERE q.sku = pp.sku AND (q.days_since_last_sale IS NULL OR q.days_since_last_sale >= 365)))::text
    UNION ALL
    SELECT 16, 'Q15 lists every customer that has an invoice',
           (SELECT count(DISTINCT customer_key) FROM mart.fact_invoice)::text,
           (SELECT count(*) FROM analysis.q15_revenue_concentration)::text
    UNION ALL
    SELECT 17, 'Q15 cumulative share ends at 100 percent (within 0.1)', 'yes',
           (SELECT CASE WHEN abs(max(cumulative_share_pct) - 100) <= 0.1 THEN 'yes' ELSE 'no' END
              FROM analysis.q15_revenue_concentration)
    UNION ALL
    SELECT 18, 'Q16 has one row per division',
           '3',
           (SELECT count(*) FROM analysis.q16_decision_time_by_division)::text
    UNION ALL
    SELECT 19, 'Q17 lists every customer that has an invoice',
           (SELECT count(DISTINCT customer_key) FROM mart.fact_invoice)::text,
           (SELECT count(*) FROM analysis.q17_customer_value_across_divisions)::text
    UNION ALL
    SELECT 20, 'Q18 equals customers with rentals and no projects billing, found a second way from Q17',
           (SELECT count(*) FROM analysis.q17_customer_value_across_divisions
             WHERE rentals_thousand > 0 AND projects_thousand = 0)::text,
           (SELECT count(*) FROM analysis.q18_rent_only_customers)::text
) t
ORDER BY n;
