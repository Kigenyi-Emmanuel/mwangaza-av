-- Mwangaza AV (synthetic case study)
-- DATA PROFILE of the raw layer. READ-ONLY: this only counts and adds up. It changes nothing.
-- Run any time after Stage 12, in the mwangaza_av database. Executed on PostgreSQL 18.6.
--
-- Why: before cleaning data, look at it. These numbers describe SYNTHETIC data. They tell us whether the
-- fictional company looks plausible (for example, which division earns most). They say nothing about any
-- real business.
-- One result table: area, what is measured, value.

SELECT area, metric, value
FROM (
    SELECT 1 AS o, 'Row counts' AS area, 'raw.customer' AS metric, count(*)::text AS value FROM raw.customer
    UNION ALL SELECT 2, 'Row counts', 'raw.supplier', count(*)::text FROM raw.supplier
    UNION ALL SELECT 3, 'Row counts', 'raw.product', count(*)::text FROM raw.product
    UNION ALL SELECT 4, 'Row counts', 'raw.asset', count(*)::text FROM raw.asset
    UNION ALL SELECT 5, 'Row counts', 'raw.quote', count(*)::text FROM raw.quote
    UNION ALL SELECT 6, 'Row counts', 'raw.job', count(*)::text FROM raw.job
    UNION ALL SELECT 7, 'Row counts', 'raw.job_cost_line', count(*)::text FROM raw.job_cost_line
    UNION ALL SELECT 8, 'Row counts', 'raw.sales_order', count(*)::text FROM raw.sales_order
    UNION ALL SELECT 9, 'Row counts', 'raw.sales_order_line', count(*)::text FROM raw.sales_order_line
    UNION ALL SELECT 10, 'Row counts', 'raw.stock_movement', count(*)::text FROM raw.stock_movement
    UNION ALL SELECT 11, 'Row counts', 'raw.rental_booking', count(*)::text FROM raw.rental_booking
    UNION ALL SELECT 12, 'Row counts', 'raw.rental_booking_line', count(*)::text FROM raw.rental_booking_line
    UNION ALL SELECT 13, 'Row counts', 'raw.maintenance_event', count(*)::text FROM raw.maintenance_event
    UNION ALL SELECT 14, 'Row counts', 'raw.invoice', count(*)::text FROM raw.invoice
    UNION ALL SELECT 15, 'Row counts', 'raw.payment', count(*)::text FROM raw.payment
    UNION ALL SELECT 16, 'Row counts', 'raw.payment_allocation', count(*)::text FROM raw.payment_allocation

    -- billing by division (planted duplicate invoices are not counted: only the real invoices)
    UNION ALL SELECT 20, 'Billing', 'Invoiced before VAT, projects (KES millions)',
        round(coalesce(sum(amount_ex_vat) FILTER (WHERE division = 'projects'), 0) / 1000000, 1)::text FROM generator.invoice_profile
    UNION ALL SELECT 21, 'Billing', 'Invoiced before VAT, products (KES millions)',
        round(coalesce(sum(amount_ex_vat) FILTER (WHERE division = 'products'), 0) / 1000000, 1)::text FROM generator.invoice_profile
    UNION ALL SELECT 22, 'Billing', 'Invoiced before VAT, rentals (KES millions)',
        round(coalesce(sum(amount_ex_vat) FILTER (WHERE division = 'rentals'), 0) / 1000000, 1)::text FROM generator.invoice_profile
    UNION ALL SELECT 23, 'Billing', 'Share of billing: projects (percent)',
        round(100 * sum(amount_ex_vat) FILTER (WHERE division = 'projects') / sum(amount_ex_vat), 1)::text FROM generator.invoice_profile
    UNION ALL SELECT 24, 'Billing', 'Share of billing: products (percent)',
        round(100 * sum(amount_ex_vat) FILTER (WHERE division = 'products') / sum(amount_ex_vat), 1)::text FROM generator.invoice_profile
    UNION ALL SELECT 25, 'Billing', 'Share of billing: rentals (percent)',
        round(100 * sum(amount_ex_vat) FILTER (WHERE division = 'rentals') / sum(amount_ex_vat), 1)::text FROM generator.invoice_profile

    -- cash
    UNION ALL SELECT 30, 'Cash', 'Total invoiced including VAT (KES millions)',
        round(sum(total_amount) / 1000000, 1)::text FROM generator.invoice_profile
    UNION ALL SELECT 31, 'Cash', 'Total allocated to invoices by payments (KES millions)',
        round(sum(allocated_amount::numeric) / 1000000, 1)::text FROM raw.payment_allocation
    UNION ALL SELECT 32, 'Cash', 'Roughly unpaid at the as-of date (KES millions)',
        round(((SELECT sum(total_amount) FROM generator.invoice_profile)
             - (SELECT sum(allocated_amount::numeric) FROM raw.payment_allocation)) / 1000000, 1)::text

    -- projects
    UNION ALL SELECT 40, 'Projects', 'Finished jobs',
        count(*) FILTER (WHERE status = 'completed')::text FROM generator.job_profile
    UNION ALL SELECT 41, 'Projects', 'Jobs still in progress',
        count(*) FILTER (WHERE status = 'in_progress')::text FROM generator.job_profile
    UNION ALL SELECT 42, 'Projects', 'Average quoted price of a job (KES millions)',
        round(avg(quoted_price) / 1000000, 2)::text FROM generator.job_profile
    UNION ALL SELECT 43, 'Projects', 'Average margin of finished jobs (percent)',
        round(100 * (1 - (SELECT sum(c.quantity::numeric * c.unit_cost::numeric)
                             FROM raw.job_cost_line c
                             JOIN generator.job_profile jp ON jp.job_number = c.job_number
                            WHERE jp.status = 'completed')
                       / (SELECT sum(quoted_price) FROM generator.job_profile WHERE status = 'completed')), 1)::text

    -- products
    UNION ALL SELECT 50, 'Products', 'Delivered sales orders',
        count(*) FILTER (WHERE status = 'delivered')::text FROM generator.sales_order_profile
    UNION ALL SELECT 51, 'Products', 'Average order value (KES thousands)',
        round(avg(revenue) / 1000, 0)::text FROM generator.sales_order_profile
    UNION ALL SELECT 52, 'Products', 'Margin on all order lines after discounts (percent)',
        round(100 * (1 - sum(quantity::numeric * unit_cost::numeric)
                       / sum(quantity::numeric * unit_price_ex_vat::numeric)), 1)::text FROM raw.sales_order_line

    -- rentals
    UNION ALL SELECT 60, 'Rentals', 'Bookings',
        count(*)::text FROM generator.rental_booking_profile
    UNION ALL SELECT 61, 'Rentals', 'Average booking value (KES thousands)',
        round(avg(revenue) / 1000, 0)::text FROM generator.rental_booking_profile
    UNION ALL SELECT 62, 'Rentals', 'Repair and service cost (KES millions)',
        round(sum(cost_amount::numeric) / 1000000, 1)::text FROM raw.maintenance_event
    UNION ALL SELECT 63, 'Rentals', 'Repair and service cost as a share of rental billing (percent)',
        round(100 * (SELECT sum(cost_amount::numeric) FROM raw.maintenance_event)
                  / (SELECT sum(amount_ex_vat) FROM generator.invoice_profile WHERE division = 'rentals'), 1)::text

    -- customers
    UNION ALL SELECT 70, 'Customers', 'Customers with at least one invoice',
        count(DISTINCT customer_code)::text FROM generator.invoice_profile
    UNION ALL SELECT 71, 'Customers', 'Share of billing from the top 10 customers (percent)',
        round(100 * (SELECT sum(t.s) FROM (SELECT sum(amount_ex_vat) AS s FROM generator.invoice_profile
                                           GROUP BY customer_code ORDER BY 1 DESC LIMIT 10) t)
                  / (SELECT sum(amount_ex_vat) FROM generator.invoice_profile), 1)::text

    -- quote win rates (won out of won + lost + expired)
    UNION ALL SELECT 80, 'Quotes', 'Win rate, projects (percent)',
        round(100 * count(*) FILTER (WHERE status = 'won')::numeric
              / nullif(count(*) FILTER (WHERE status IN ('won', 'lost', 'expired')), 0), 1)::text
        FROM raw.quote WHERE division = 'projects'
    UNION ALL SELECT 81, 'Quotes', 'Win rate, products (percent)',
        round(100 * count(*) FILTER (WHERE status = 'won')::numeric
              / nullif(count(*) FILTER (WHERE status IN ('won', 'lost', 'expired')), 0), 1)::text
        FROM raw.quote WHERE division = 'products'
    UNION ALL SELECT 82, 'Quotes', 'Win rate, rentals (percent)',
        round(100 * count(*) FILTER (WHERE status = 'won')::numeric
              / nullif(count(*) FILTER (WHERE status IN ('won', 'lost', 'expired')), 0), 1)::text
        FROM raw.quote WHERE division = 'rentals'
) p
ORDER BY o;
