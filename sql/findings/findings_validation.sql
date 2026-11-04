-- Mwangaza AV (synthetic case study)
-- Validation of the findings in docs/findings.md. READ-ONLY: it only reads and calculates.
-- Run after Stage 19, in the mwangaza_av database. Status: not yet executed.
--
-- Purpose:
--   Tests the explanations offered in the findings (for example, whether sector margins differ because of job mix)
--   and compares what the analysis found with the hidden answer key (generator schema).
-- One result table: finding, item, value.

SELECT finding, item, value
FROM (
    -- F1: how much one job type moves the overall margin
    SELECT 1 AS o, 'F1 margin of finished jobs' AS finding, 'all job types' AS item,
           round(100 * sum(gross_profit) / sum(invoiced_ex_vat), 1) || '%' AS value
    FROM mart.fact_job_margin
    WHERE is_finished
    UNION ALL
    SELECT 1, 'F1 margin of finished jobs', 'without Auditorium and hall fit-out',
           round(100 * sum(f.gross_profit) / sum(f.invoiced_ex_vat), 1) || '%'
    FROM mart.fact_job_margin f
    JOIN mart.dim_job j ON j.job_key = f.job_key
    WHERE f.is_finished AND j.job_type_name <> 'Auditorium and hall fit-out'
    UNION ALL
    -- F3: do sector margins differ only because of job mix?
    SELECT 2, 'F3 sector margin without Auditorium jobs', dc.sector_name,
           count(*) || ' jobs; margin ' || round(100 * sum(f.gross_profit) / sum(f.invoiced_ex_vat), 1) || '%'
    FROM mart.fact_job_margin f
    JOIN mart.dim_job j ON j.job_key = f.job_key
    JOIN mart.dim_customer dc ON dc.customer_key = f.customer_key
    WHERE f.is_finished AND j.job_type_name <> 'Auditorium and hall fit-out'
    GROUP BY dc.sector_name
    UNION ALL
    SELECT 3, 'F3 Auditorium jobs by sector', dc.sector_name,
           count(*) FILTER (WHERE j.job_type_name = 'Auditorium and hall fit-out') || ' of ' || count(*) || ' finished jobs'
    FROM mart.fact_job_margin f
    JOIN mart.dim_job j ON j.job_key = f.job_key
    JOIN mart.dim_customer dc ON dc.customer_key = f.customer_key
    WHERE f.is_finished
    GROUP BY dc.sector_name
    UNION ALL
    -- F5: where do the planted habitual late payers rank among the slowest payers?
    SELECT 4, 'F5 planted late payers: rank among the slowest payers', r.customer_code || ' ' || r.customer_name,
           'rank ' || r.rn || ' of ' || r.total || '; ' || r.weighted_days_after_due || ' days after due'
    FROM (SELECT q.*, row_number() OVER (ORDER BY q.weighted_days_after_due DESC) AS rn, count(*) OVER () AS total
          FROM analysis.q04_slowest_payers q) r
    JOIN generator.payer_profile pp ON pp.customer_code = r.customer_code AND pp.payer_type = 'late'
    UNION ALL
    SELECT 4, 'F5 planted late payers not listed in Q04 (fewer than 10 payments)', 'count',
           (SELECT count(*) FROM generator.payer_profile pp
             WHERE pp.payer_type = 'late'
               AND pp.customer_code NOT IN (SELECT customer_code FROM analysis.q04_slowest_payers))::text
    UNION ALL
    -- F12: does the slow-decision effect show inside each division?
    SELECT 5, 'F12 win rate by decision time and division', x.division_name || ' | ' || x.speed,
           x.n || ' decided; ' || x.rate || '% won'
    FROM (SELECT dd.division_name,
                 CASE WHEN q.days_to_decide > 45 THEN 'over 45 days' ELSE '45 days or less' END AS speed,
                 count(*) AS n,
                 round(100.0 * count(*) FILTER (WHERE q.is_won) / count(*), 1) AS rate
          FROM mart.fact_quote q
          JOIN mart.dim_division dd ON dd.division_key = q.division_key
          WHERE q.status IN ('won', 'lost')
          GROUP BY dd.division_name, CASE WHEN q.days_to_decide > 45 THEN 'over 45 days' ELSE '45 days or less' END) x
    UNION ALL
    -- F11: are rental quotes that were lost priced differently from those that were won?
    SELECT 6, 'F11 rental quotes: average price by outcome', q.status,
           count(*) || ' quotes; average ' || round(avg(q.quoted_price_ex_vat) / 1000, 0) || 'k'
    FROM mart.fact_quote q
    WHERE q.division_key = 3 AND q.status IN ('won', 'lost', 'expired')
    GROUP BY q.status
    UNION ALL
    -- F7: weight of the assets on hire under 10 percent of the time
    SELECT 7, 'F7 assets on hire under 10 percent', 'share of all repair and service cost',
           round(100 * (SELECT sum(repair_and_service_cost) FROM analysis.q08_idle_assets_and_repair_cost)
                 / (SELECT sum(cost_amount) FROM mart.fact_maintenance), 1) || '%'
    UNION ALL
    SELECT 7, 'F7 assets on hire under 10 percent', 'share of all rental revenue',
           round(100 * (SELECT sum(rental_revenue) FROM analysis.q08_idle_assets_and_repair_cost)
                 / (SELECT sum(rental_revenue) FROM mart.fact_asset_day), 2) || '%'
    UNION ALL
    -- F9: repair cost against revenue by category, without those assets
    SELECT 8, 'F9 repair and service cost as a share of revenue, without those assets', rv.category_name,
           round(100 * rp.cost / rv.revenue, 1) || '%'
    FROM (SELECT a.category_name, sum(f.rental_revenue) AS revenue
          FROM mart.fact_asset_day f
          JOIN mart.dim_asset a ON a.asset_key = f.asset_key
          WHERE a.asset_tag NOT IN (SELECT asset_tag FROM analysis.q08_idle_assets_and_repair_cost)
          GROUP BY a.category_name) rv
    JOIN (SELECT a.category_name, sum(m.cost_amount) AS cost
          FROM mart.fact_maintenance m
          JOIN mart.dim_asset a ON a.asset_key = m.asset_key
          WHERE a.asset_tag NOT IN (SELECT asset_tag FROM analysis.q08_idle_assets_and_repair_cost)
          GROUP BY a.category_name) rp ON rp.category_name = rv.category_name
    UNION ALL
    -- F10: double-bookings
    SELECT 9, 'F10 double-booked pairs and assets', 'pairs and distinct assets',
           count(*) || ' pairs; ' || count(DISTINCT asset_tag) || ' assets'
    FROM analysis.q09_double_booked_assets
    UNION ALL
    -- F13: stock without a sale for a year or more
    SELECT 10, 'F13 products without a sale for a year or more', 'products and stock value at cost',
           count(*) || ' products; ' || round(coalesce(sum(stock_value_at_cost), 0) / 1000000, 1) || 'm'
    FROM analysis.q14_stock_without_recent_sales
    WHERE days_since_last_sale IS NULL OR days_since_last_sale >= 365
    UNION ALL
    SELECT 10, 'F13 products without a sale for a year or more', 'of which never sold',
           count(*) || ' products; ' || round(coalesce(sum(stock_value_at_cost), 0) / 1000000, 1) || 'm'
    FROM analysis.q14_stock_without_recent_sales
    WHERE days_since_last_sale IS NULL
    UNION ALL
    SELECT 10, 'F13 products without a sale for a year or more', 'planted dead-stock products (answer key)',
           count(*) || ' products'
    FROM generator.product_profile
    WHERE is_dead_stock
) t
ORDER BY o, finding, item;
