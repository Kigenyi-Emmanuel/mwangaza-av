-- Mwangaza AV (synthetic case study)
-- Headline results of the 18 business questions (Stage 19) in one result table. READ-ONLY.
-- Run after Stage 19, in the mwangaza_av database. Status: not yet executed.
--
-- Columns: question, item, detail. Small views are shown in full; long ones show their top rows.
-- The full results are available from each view: SELECT * FROM analysis.q01_margin_by_job_type; and so on.

SELECT question, item, detail
FROM (
    SELECT 1 AS o, row_number() OVER (ORDER BY weighted_actual_margin_pct) AS r,
           'Q01 margin by job type' AS question, job_type_name AS item,
           concat_ws('; ', finished_jobs || ' jobs', billed_million || 'm billed',
                     'quoted margin ' || avg_quoted_margin_pct || '%',
                     'actual margin ' || weighted_actual_margin_pct || '%',
                     'variance ' || avg_variance_pts || ' pts') AS detail
    FROM analysis.q01_margin_by_job_type
    UNION ALL
    SELECT 2, row_number() OVER (ORDER BY weighted_actual_margin_pct), 'Q02 margin by sector', sector_name,
           concat_ws('; ', finished_jobs || ' jobs', billed_million || 'm billed',
                     'quoted margin ' || avg_quoted_margin_pct || '%',
                     'actual margin ' || weighted_actual_margin_pct || '%',
                     'variance ' || avg_variance_pts || ' pts')
    FROM analysis.q02_margin_by_sector
    UNION ALL
    SELECT 3, row_number() OVER (ORDER BY division_name, outstanding_million DESC), 'Q03 unpaid invoices by age',
           division_name || ' | ' || ageing_bucket,
           concat_ws('; ', invoices || ' invoices', outstanding_million || 'm', share_of_outstanding_pct || '% of unpaid')
    FROM analysis.q03_ageing_of_unpaid_invoices
    UNION ALL
    SELECT 4, row_number() OVER (ORDER BY s.weighted_days_after_due DESC), 'Q04 slowest payers (top 6)',
           s.customer_code || ' ' || s.customer_name,
           concat_ws('; ', s.sector_name, 'terms ' || s.payment_terms_days || ' days',
                     s.payments_applied || ' payments', s.weighted_days_after_due || ' days after due')
    FROM (SELECT * FROM analysis.q04_slowest_payers ORDER BY weighted_days_after_due DESC LIMIT 6) s
    UNION ALL
    SELECT 5, row_number() OVER (ORDER BY calendar_year, calendar_quarter), 'Q05 payment speed by quarter',
           calendar_year || ' Q' || calendar_quarter,
           concat_ws('; ', payments_applied || ' payments', weighted_days_after_due || ' days after due',
                     'change ' || change_vs_previous_quarter)
    FROM analysis.q05_payment_speed_by_quarter
    UNION ALL
    SELECT 6, row_number() OVER (ORDER BY commissioning_pts_vs_all_jobs DESC), 'Q06 cost mix by job type',
           job_type_name,
           concat_ws('; ', 'equipment ' || equipment_pct || '%', 'installation ' || installation_labour_pct || '%',
                     'commissioning ' || commissioning_labour_pct || '%', 'subcontractor ' || subcontractor_pct || '%',
                     'transport ' || transport_pct || '%', 'commissioning vs all jobs ' || commissioning_pts_vs_all_jobs || ' pts')
    FROM analysis.q06_cost_mix_by_job_type
    UNION ALL
    SELECT 7, row_number() OVER (ORDER BY time_utilisation_pct DESC), 'Q07 utilisation by asset category',
           category_name,
           concat_ws('; ', assets || ' assets', 'on hire ' || time_utilisation_pct || '%',
                     'out of service ' || out_of_service_pct || '%', revenue_million || 'm revenue')
    FROM analysis.q07_utilisation_by_category
    UNION ALL
    SELECT 8, row_number() OVER (ORDER BY time_utilisation_pct), 'Q08 assets on hire under 10 percent',
           asset_tag || ' ' || asset_name,
           concat_ws('; ', category_name, 'on hire ' || time_utilisation_pct || '%',
                     'revenue ' || rental_revenue, 'repairs and services ' || repair_and_service_cost,
                     damage_events || ' damage events', 'repairs ' || repair_cost_pct_of_revenue || '% of revenue')
    FROM analysis.q08_idle_assets_and_repair_cost
    UNION ALL
    SELECT 9, row_number() OVER (ORDER BY overlapping_days DESC, asset_tag), 'Q09 double-booked assets',
           asset_tag || ' ' || asset_name,
           concat_ws('; ', first_booking || ' (' || first_start || ' to ' || first_end || ')',
                     second_booking || ' (' || second_start || ' to ' || second_end || ')',
                     overlapping_days || ' overlapping days')
    FROM analysis.q09_double_booked_assets
    UNION ALL
    SELECT 10, row_number() OVER (ORDER BY repair_and_service_pct_of_revenue DESC), 'Q10 repair economics by category',
           category_name,
           concat_ws('; ', revenue_million || 'm revenue', damage_repairs_million || 'm damage repairs',
                     routine_service_million || 'm services', days_out_of_service || ' days out of service',
                     repair_and_service_pct_of_revenue || '% of revenue')
    FROM analysis.q10_repair_economics_by_category
    UNION ALL
    SELECT 11, row_number() OVER (ORDER BY s.idle_days DESC, s.asset_tag), 'Q11 longest idle gaps (top 5)',
           s.asset_tag || ' ' || s.asset_name,
           concat_ws('; ', s.asset_category_name, s.idle_days || ' idle days', 'from ' || s.booking_ends || ' to ' || s.next_booking_starts)
    FROM (SELECT * FROM analysis.q11_longest_idle_gaps ORDER BY idle_days DESC, asset_tag LIMIT 5) s
    UNION ALL
    SELECT 12, row_number() OVER (ORDER BY division_name, price_band), 'Q12 win rate by division and quote size',
           division_name || ' | ' || price_band,
           concat_ws('; ', closed_quotes || ' closed', won_quotes || ' won', win_rate_pct || '% win rate')
    FROM analysis.q12_win_rate_by_division_and_size
    UNION ALL
    SELECT 13, row_number() OVER (ORDER BY decision_speed), 'Q13 win rate by decision speed',
           decision_speed,
           concat_ws('; ', decided_quotes || ' decided', won_quotes || ' won', win_rate_pct || '% win rate')
    FROM analysis.q13_win_rate_by_decision_speed
    UNION ALL
    SELECT 14, row_number() OVER (ORDER BY s.days_since_last_sale DESC NULLS FIRST, s.stock_value_at_cost DESC),
           'Q14 products without recent sales (top 8)',
           s.sku || ' ' || s.product_name,
           concat_ws('; ', s.category_name, 'last sale ' || s.last_sale_date,
                     s.days_since_last_sale || ' days ago', s.stock_on_hand || ' in stock',
                     'stock value ' || s.stock_value_at_cost)
    FROM (SELECT * FROM analysis.q14_stock_without_recent_sales LIMIT 8) s
    UNION ALL
    SELECT 15, rank_no, 'Q15 revenue concentration (top 8)',
           customer_code || ' ' || customer_name,
           concat_ws('; ', sector_name, billed_million || 'm billed', share_pct || '% of billing',
                     'cumulative ' || cumulative_share_pct || '%')
    FROM analysis.q15_revenue_concentration
    WHERE rank_no <= 8
    UNION ALL
    SELECT 15, 100, 'Q15 revenue concentration (summary)', 'customers needed for 80 percent of billing',
           (SELECT min(rank_no) FROM analysis.q15_revenue_concentration WHERE cumulative_share_pct >= 80)
           || ' of ' || (SELECT count(*) FROM analysis.q15_revenue_concentration)
    UNION ALL
    SELECT 16, row_number() OVER (ORDER BY division_name), 'Q16 decision time by division',
           division_name,
           concat_ws('; ', decided_quotes || ' decided', 'median ' || median_days || ' days',
                     '90th percentile ' || p90_days || ' days', 'longest ' || longest_days || ' days')
    FROM analysis.q16_decision_time_by_division
    UNION ALL
    SELECT 17, row_number() OVER (ORDER BY s.total_thousand DESC), 'Q17 customer value across divisions (top 8)',
           s.customer_code || ' ' || s.customer_name,
           concat_ws('; ', s.sector_name, 'projects ' || s.projects_thousand || 'k', 'products ' || s.products_thousand || 'k',
                     'rentals ' || s.rentals_thousand || 'k', 'total ' || s.total_thousand || 'k',
                     s.divisions_used || ' divisions')
    FROM (SELECT * FROM analysis.q17_customer_value_across_divisions ORDER BY total_thousand DESC LIMIT 8) s
    UNION ALL
    SELECT 17, 100, 'Q17 customer value across divisions (summary)', 'customers billed in all three divisions',
           (SELECT count(*) FILTER (WHERE divisions_used = 3) FROM analysis.q17_customer_value_across_divisions)
           || ' of ' || (SELECT count(*) FROM analysis.q17_customer_value_across_divisions)
    UNION ALL
    SELECT 18, row_number() OVER (ORDER BY s.rentals_thousand DESC), 'Q18 customers who rent but never had a project (top 8)',
           s.customer_code || ' ' || s.customer_name,
           concat_ws('; ', s.sector_name, s.rental_invoices || ' rental invoices', 'rentals ' || s.rentals_thousand || 'k')
    FROM (SELECT * FROM analysis.q18_rent_only_customers ORDER BY rentals_thousand DESC LIMIT 8) s
    UNION ALL
    SELECT 18, 100, 'Q18 customers who rent but never had a project (summary)', 'customers in this group',
           (SELECT count(*) FROM analysis.q18_rent_only_customers)::text
) t
ORDER BY o, r;
