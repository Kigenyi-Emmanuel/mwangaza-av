-- Mwangaza AV (synthetic case study)
-- Stage 18: reporting layer (star schema) in the mart schema.
-- Run order: once, in the mwangaza_av database, after Stage 17. Status: not yet executed.
--
-- Purpose:
--   Builds 8 dimension tables and 9 fact tables from the core tables. The SQL analysis and the Power BI pages
--   read from this layer only. The grain of each fact table is documented in docs/star-schema.md.
--
-- Design notes:
--   * Dimension keys reuse the core ids, so every mart row can be traced back to its core row.
--   * "Not applicable" is a real dimension member with key 0 (dim_date: no date; dim_job: not a projects
--     invoice), so fact tables never hold empty keys.
--   * fact_invoice exposes one combined source column (source_number) instead of the three optional core links.
--   * Sums over child rows (amount paid, job cost, job billing) are calculated once per parent before joining,
--     so no row is counted twice.
--   * The mart is built from the core tables only. The generator answer key is not read here.
--   * The as-of date (2026-09-30), the start of history and the currency are held in mart.report_info.
--
-- Safety: runs as a single transaction (BEGIN ... COMMIT); if any statement fails, nothing is saved.
-- The script creates new tables only and does not modify core, staging or raw data.

BEGIN;

-- Step 1: safety checks
DO $$
BEGIN
    IF (SELECT count(*) FROM core.invoice) = 0 OR (SELECT count(*) FROM core.payment_allocation) = 0 THEN
        RAISE EXCEPTION 'Stop: the core tables are empty (run Stage 17 first). Nothing was changed.';
    END IF;
    IF to_regclass('mart.dim_date') IS NOT NULL THEN
        RAISE EXCEPTION 'Stop: the mart tables already exist. Nothing was changed.';
    END IF;
END $$;

-- Step 2: report information and dimensions
CREATE TABLE mart.report_info (
    as_of_date     date NOT NULL,
    history_start  date NOT NULL,
    currency       text NOT NULL,
    note           text NOT NULL
);
INSERT INTO mart.report_info (as_of_date, history_start, currency, note)
VALUES (DATE '2026-09-30', DATE '2023-10-01', 'KES',
        'Synthetic data. Amounts are before VAT unless the column name says otherwise.');

CREATE TABLE mart.dim_date (
    date_key      integer PRIMARY KEY,          -- yyyymmdd; 0 = no date
    full_date     date UNIQUE,
    year          integer,
    quarter       integer,
    month         integer,
    month_name    text NOT NULL,
    year_month    text NOT NULL,
    week_of_year  integer,
    day_of_week   integer,                      -- 1 = Monday ... 7 = Sunday
    day_name      text NOT NULL,
    is_weekend    boolean NOT NULL
);
INSERT INTO mart.dim_date (date_key, full_date, year, quarter, month, month_name, year_month, week_of_year,
                           day_of_week, day_name, is_weekend)
VALUES (0, NULL, NULL, NULL, NULL, 'No date', 'No date', NULL, NULL, 'No date', false);
INSERT INTO mart.dim_date (date_key, full_date, year, quarter, month, month_name, year_month, week_of_year,
                           day_of_week, day_name, is_weekend)
SELECT to_char(g.d, 'YYYYMMDD')::int, g.d::date, extract(year FROM g.d)::int, extract(quarter FROM g.d)::int,
       extract(month FROM g.d)::int, to_char(g.d, 'Mon'), to_char(g.d, 'YYYY-MM'), extract(week FROM g.d)::int,
       extract(isodow FROM g.d)::int, to_char(g.d, 'Dy'), extract(isodow FROM g.d) IN (6, 7)
FROM generate_series(DATE '2019-01-01'::timestamp, DATE '2026-12-31'::timestamp, INTERVAL '1 day') AS g(d);

CREATE TABLE mart.dim_division (
    division_key   integer PRIMARY KEY,
    division_code  text NOT NULL UNIQUE,
    division_name  text NOT NULL
);
INSERT INTO mart.dim_division (division_key, division_code, division_name)
VALUES (1, 'projects', 'Projects'), (2, 'products', 'Products'), (3, 'rentals', 'Rentals');

CREATE TABLE mart.dim_office (
    office_key   integer PRIMARY KEY,
    office_name  text NOT NULL,
    country      text NOT NULL
);
INSERT INTO mart.dim_office (office_key, office_name, country)
SELECT office_id, office_name, country FROM core.office;

CREATE TABLE mart.dim_customer (
    customer_key        integer PRIMARY KEY,
    customer_code       text NOT NULL,
    customer_name       text NOT NULL,
    sector_name         text NOT NULL,
    payment_terms_days  integer NOT NULL,
    customer_since      date NOT NULL
);
INSERT INTO mart.dim_customer (customer_key, customer_code, customer_name, sector_name, payment_terms_days, customer_since)
SELECT c.customer_id, c.customer_code, c.customer_name, s.sector_name, c.payment_terms_days, c.created_date
FROM core.customer c
JOIN core.sector s ON s.sector_id = c.sector_id;

CREATE TABLE mart.dim_product (
    product_key       integer PRIMARY KEY,
    sku               text NOT NULL,
    product_name      text NOT NULL,
    category_name     text NOT NULL,
    supplier_name     text NOT NULL,
    supplier_country  text NOT NULL,
    list_price_ex_vat numeric(14,2) NOT NULL,
    standard_cost     numeric(14,2) NOT NULL,
    is_active         boolean NOT NULL
);
INSERT INTO mart.dim_product (product_key, sku, product_name, category_name, supplier_name, supplier_country,
                              list_price_ex_vat, standard_cost, is_active)
SELECT p.product_id, p.sku, p.product_name, pc.product_category_name, s.supplier_name, s.country,
       p.list_price_ex_vat, p.standard_cost, p.is_active
FROM core.product p
JOIN core.product_category pc ON pc.product_category_id = p.product_category_id
JOIN core.supplier s ON s.supplier_id = p.supplier_id;

CREATE TABLE mart.dim_asset (
    asset_key          integer PRIMARY KEY,
    asset_tag          text NOT NULL,
    asset_name         text NOT NULL,
    category_name      text NOT NULL,
    purchase_date      date NOT NULL,
    purchase_cost      numeric(14,2) NOT NULL,
    daily_rate_ex_vat  numeric(14,2) NOT NULL,
    status             text NOT NULL,
    retired_date       date
);
INSERT INTO mart.dim_asset (asset_key, asset_tag, asset_name, category_name, purchase_date, purchase_cost,
                            daily_rate_ex_vat, status, retired_date)
SELECT a.asset_id, a.asset_tag, a.asset_name, ac.asset_category_name, a.purchase_date, a.purchase_cost,
       a.daily_rate_ex_vat, a.status, a.retired_date
FROM core.asset a
JOIN core.asset_category ac ON ac.asset_category_id = a.asset_category_id;

CREATE TABLE mart.dim_job (
    job_key        integer PRIMARY KEY,         -- 0 = not applicable (the invoice is not for a projects job)
    job_number     text NOT NULL,
    job_type_name  text NOT NULL,
    status         text NOT NULL,
    start_date     date,
    end_date       date
);
INSERT INTO mart.dim_job (job_key, job_number, job_type_name, status, start_date, end_date)
VALUES (0, 'N/A', 'Not applicable', 'n/a', NULL, NULL);
INSERT INTO mart.dim_job (job_key, job_number, job_type_name, status, start_date, end_date)
SELECT j.job_id, j.job_number, jt.job_type_name, j.status, j.start_date, j.end_date
FROM core.job j
JOIN core.job_type jt ON jt.job_type_id = j.job_type_id;

CREATE TABLE mart.dim_cost_category (
    cost_category_key  integer PRIMARY KEY,
    cost_category_name text NOT NULL,
    is_labour          boolean NOT NULL
);
INSERT INTO mart.dim_cost_category (cost_category_key, cost_category_name, is_labour)
SELECT cost_category_id, cost_category_name, cost_category_name ILIKE '%labour%'
FROM core.cost_category;

-- Step 3: fact tables
CREATE TABLE mart.fact_invoice (
    invoice_key             integer PRIMARY KEY,
    invoice_number          text NOT NULL,
    invoice_date_key        integer NOT NULL REFERENCES mart.dim_date (date_key),
    due_date_key            integer NOT NULL REFERENCES mart.dim_date (date_key),
    first_payment_date_key  integer NOT NULL REFERENCES mart.dim_date (date_key),   -- 0 = unpaid
    last_payment_date_key   integer NOT NULL REFERENCES mart.dim_date (date_key),   -- 0 = unpaid
    customer_key            integer NOT NULL REFERENCES mart.dim_customer (customer_key),
    division_key            integer NOT NULL REFERENCES mart.dim_division (division_key),
    office_key              integer NOT NULL REFERENCES mart.dim_office (office_key),
    job_key                 integer NOT NULL REFERENCES mart.dim_job (job_key),     -- 0 = not a projects invoice
    source_number           text NOT NULL,                                          -- job, order or booking number
    amount_ex_vat           numeric(14,2) NOT NULL,
    vat_amount              numeric(14,2) NOT NULL,
    total_amount            numeric(14,2) NOT NULL,
    paid_amount             numeric(14,2) NOT NULL,
    outstanding_amount      numeric(14,2) NOT NULL,
    is_fully_paid           boolean NOT NULL,
    days_past_due_at_asof   integer NOT NULL,
    ageing_bucket           text NOT NULL
);

CREATE TABLE mart.fact_payment_allocation (
    allocation_key     integer PRIMARY KEY,
    payment_reference  text NOT NULL,
    payment_method     text NOT NULL,
    payment_date_key   integer NOT NULL REFERENCES mart.dim_date (date_key),
    invoice_key        integer NOT NULL,                                            -- points to fact_invoice
    invoice_number     text NOT NULL,
    customer_key       integer NOT NULL REFERENCES mart.dim_customer (customer_key),
    division_key       integer NOT NULL REFERENCES mart.dim_division (division_key),
    allocated_amount   numeric(14,2) NOT NULL,
    days_from_invoice  integer NOT NULL,
    days_after_due     integer NOT NULL
);

CREATE TABLE mart.fact_job_cost_line (
    cost_line_key      integer PRIMARY KEY,
    job_key            integer NOT NULL REFERENCES mart.dim_job (job_key),
    cost_category_key  integer NOT NULL REFERENCES mart.dim_cost_category (cost_category_key),
    date_key           integer NOT NULL REFERENCES mart.dim_date (date_key),
    quantity           numeric(12,2) NOT NULL,
    unit_cost          numeric(14,2) NOT NULL,
    cost_amount        numeric(14,2) NOT NULL
);

CREATE TABLE mart.fact_job_margin (
    job_key                    integer PRIMARY KEY REFERENCES mart.dim_job (job_key),
    customer_key               integer NOT NULL REFERENCES mart.dim_customer (customer_key),
    office_key                 integer NOT NULL REFERENCES mart.dim_office (office_key),
    start_date_key             integer NOT NULL REFERENCES mart.dim_date (date_key),
    end_date_key               integer NOT NULL REFERENCES mart.dim_date (date_key),   -- 0 = still in progress
    is_finished                boolean NOT NULL,
    quote_number               text,
    quoted_price_ex_vat        numeric(14,2),
    quoted_cost                numeric(14,2),
    invoiced_ex_vat            numeric(14,2) NOT NULL,
    actual_cost                numeric(14,2) NOT NULL,
    equipment_cost             numeric(14,2) NOT NULL,
    installation_labour_cost   numeric(14,2) NOT NULL,
    commissioning_labour_cost  numeric(14,2) NOT NULL,
    subcontractor_cost         numeric(14,2) NOT NULL,
    transport_cost             numeric(14,2) NOT NULL,
    gross_profit               numeric(14,2) NOT NULL,
    gross_margin_pct           numeric(8,2),
    quoted_margin_pct          numeric(8,2),
    margin_variance_pts        numeric(8,2)
);

CREATE TABLE mart.fact_quote (
    quote_key            integer PRIMARY KEY,
    quote_number         text NOT NULL,
    quote_date_key       integer NOT NULL REFERENCES mart.dim_date (date_key),
    decision_date_key    integer NOT NULL REFERENCES mart.dim_date (date_key),       -- 0 = not decided
    customer_key         integer NOT NULL REFERENCES mart.dim_customer (customer_key),
    division_key         integer NOT NULL REFERENCES mart.dim_division (division_key),
    office_key           integer NOT NULL REFERENCES mart.dim_office (office_key),
    job_key              integer NOT NULL REFERENCES mart.dim_job (job_key),         -- 0 = no job came from this quote
    status               text NOT NULL,
    is_won               boolean NOT NULL,
    is_closed            boolean NOT NULL,                                           -- won, lost or expired
    days_to_decide       integer,
    quoted_price_ex_vat  numeric(14,2) NOT NULL,
    quoted_cost          numeric(14,2) NOT NULL,
    quoted_margin_pct    numeric(8,2)
);

CREATE TABLE mart.fact_sales_line (
    sales_line_key     integer PRIMARY KEY,
    order_number       text NOT NULL,
    order_date_key     integer NOT NULL REFERENCES mart.dim_date (date_key),
    customer_key       integer NOT NULL REFERENCES mart.dim_customer (customer_key),
    office_key         integer NOT NULL REFERENCES mart.dim_office (office_key),
    product_key        integer NOT NULL REFERENCES mart.dim_product (product_key),
    order_status       text NOT NULL,
    quantity           integer NOT NULL,
    unit_price_ex_vat  numeric(14,2) NOT NULL,
    unit_cost          numeric(14,2) NOT NULL,
    revenue            numeric(14,2) NOT NULL,
    cost               numeric(14,2) NOT NULL,
    gross_margin       numeric(14,2) NOT NULL
);

CREATE TABLE mart.fact_stock_movement (
    stock_movement_key  integer PRIMARY KEY,
    date_key            integer NOT NULL REFERENCES mart.dim_date (date_key),
    product_key         integer NOT NULL REFERENCES mart.dim_product (product_key),
    movement_type       text NOT NULL,
    quantity_change     integer NOT NULL,
    unit_cost           numeric(14,2) NOT NULL,
    movement_value      numeric(16,2) NOT NULL,
    balance_after       integer NOT NULL
);

CREATE TABLE mart.fact_maintenance (
    maintenance_key      integer PRIMARY KEY,
    date_key             integer NOT NULL REFERENCES mart.dim_date (date_key),
    asset_key            integer NOT NULL REFERENCES mart.dim_asset (asset_key),
    event_type           text NOT NULL,
    cost_amount          numeric(14,2) NOT NULL,
    days_out_of_service  integer NOT NULL,
    booking_number       text
);

CREATE TABLE mart.fact_asset_day (
    asset_key        integer NOT NULL REFERENCES mart.dim_asset (asset_key),
    date_key         integer NOT NULL REFERENCES mart.dim_date (date_key),
    bookings_count   integer NOT NULL,
    on_hire          integer NOT NULL,           -- 1 if at least one booking covers the day
    rental_revenue   numeric(14,2) NOT NULL,
    out_of_service   integer NOT NULL,           -- 1 if a repair keeps the asset out of service that day
    PRIMARY KEY (asset_key, date_key)
);

-- Step 4: load the facts from core
INSERT INTO mart.fact_invoice
    (invoice_key, invoice_number, invoice_date_key, due_date_key, first_payment_date_key, last_payment_date_key,
     customer_key, division_key, office_key, job_key, source_number, amount_ex_vat, vat_amount, total_amount,
     paid_amount, outstanding_amount, is_fully_paid, days_past_due_at_asof, ageing_bucket)
SELECT x.invoice_id, x.invoice_number, x.invoice_date_key, x.due_date_key, x.first_key, x.last_key,
       x.customer_id, x.division_key, x.office_id, x.job_key, x.source_number, x.amount_ex_vat, x.vat_amount,
       x.total_amount, x.paid, x.outstanding, x.outstanding <= 0.005,
       CASE WHEN x.outstanding > 0.005 THEN GREATEST(0, x.asof - x.due_date) ELSE 0 END,
       CASE WHEN x.outstanding <= 0.005 THEN 'Paid'
            WHEN x.asof <= x.due_date THEN 'Not yet due'
            WHEN x.asof - x.due_date <= 30 THEN '1 to 30 days overdue'
            WHEN x.asof - x.due_date <= 60 THEN '31 to 60 days overdue'
            WHEN x.asof - x.due_date <= 90 THEN '61 to 90 days overdue'
            ELSE 'Over 90 days overdue' END
FROM (
    SELECT i.invoice_id, i.invoice_number,
           to_char(i.invoice_date, 'YYYYMMDD')::int AS invoice_date_key,
           to_char(i.due_date, 'YYYYMMDD')::int AS due_date_key,
           coalesce(p.first_key, 0) AS first_key, coalesce(p.last_key, 0) AS last_key,
           i.customer_id, dv.division_key,
           coalesce(j.office_id, so.office_id, rb.office_id) AS office_id,
           coalesce(i.job_id, 0) AS job_key,
           coalesce(j.job_number, so.order_number, rb.booking_number) AS source_number,
           i.amount_ex_vat, i.vat_amount, i.total_amount,
           coalesce(p.paid, 0) AS paid,
           i.total_amount - coalesce(p.paid, 0) AS outstanding,
           i.due_date, ri.as_of_date AS asof
    FROM core.invoice i
    JOIN mart.dim_division dv ON dv.division_code = i.division
    LEFT JOIN core.job j ON j.job_id = i.job_id
    LEFT JOIN core.sales_order so ON so.sales_order_id = i.sales_order_id
    LEFT JOIN core.rental_booking rb ON rb.rental_booking_id = i.rental_booking_id
    LEFT JOIN (SELECT a.invoice_id,
                      sum(a.allocated_amount) AS paid,
                      min(to_char(py.payment_date, 'YYYYMMDD')::int) AS first_key,
                      max(to_char(py.payment_date, 'YYYYMMDD')::int) AS last_key
                 FROM core.payment_allocation a
                 JOIN core.payment py ON py.payment_id = a.payment_id
                GROUP BY a.invoice_id) p ON p.invoice_id = i.invoice_id
    CROSS JOIN mart.report_info ri
) x;

INSERT INTO mart.fact_payment_allocation
    (allocation_key, payment_reference, payment_method, payment_date_key, invoice_key, invoice_number,
     customer_key, division_key, allocated_amount, days_from_invoice, days_after_due)
SELECT a.payment_allocation_id, py.payment_reference, py.payment_method,
       to_char(py.payment_date, 'YYYYMMDD')::int, a.invoice_id, i.invoice_number,
       py.customer_id, dv.division_key, a.allocated_amount,
       py.payment_date - i.invoice_date, py.payment_date - i.due_date
FROM core.payment_allocation a
JOIN core.payment py ON py.payment_id = a.payment_id
JOIN core.invoice i ON i.invoice_id = a.invoice_id
JOIN mart.dim_division dv ON dv.division_code = i.division;

INSERT INTO mart.fact_job_cost_line (cost_line_key, job_key, cost_category_key, date_key, quantity, unit_cost, cost_amount)
SELECT l.job_cost_line_id, l.job_id, l.cost_category_id, to_char(l.cost_date, 'YYYYMMDD')::int,
       l.quantity, l.unit_cost, l.cost_amount
FROM core.job_cost_line l;

INSERT INTO mart.fact_job_margin
    (job_key, customer_key, office_key, start_date_key, end_date_key, is_finished, quote_number,
     quoted_price_ex_vat, quoted_cost, invoiced_ex_vat, actual_cost, equipment_cost, installation_labour_cost,
     commissioning_labour_cost, subcontractor_cost, transport_cost, gross_profit, gross_margin_pct,
     quoted_margin_pct, margin_variance_pts)
SELECT z.job_id, z.customer_id, z.office_id, z.start_key, z.end_key, z.is_finished, z.quote_number,
       z.quoted_price, z.quoted_cost, z.invoiced, z.cost_total, z.equipment, z.installation, z.commissioning,
       z.subcontractor, z.transport, z.invoiced - z.cost_total, z.gm, z.qm, z.gm - z.qm
FROM (
    SELECT j.job_id, j.customer_id, j.office_id,
           to_char(j.start_date, 'YYYYMMDD')::int AS start_key,
           coalesce(to_char(j.end_date, 'YYYYMMDD')::int, 0) AS end_key,
           (j.status = 'completed') AS is_finished,
           q.quote_number, q.quoted_price_ex_vat AS quoted_price, q.quoted_cost,
           coalesce(inv.invoiced, 0) AS invoiced,
           coalesce(c.total, 0) AS cost_total,
           coalesce(c.equipment, 0) AS equipment,
           coalesce(c.installation, 0) AS installation,
           coalesce(c.commissioning, 0) AS commissioning,
           coalesce(c.subcontractor, 0) AS subcontractor,
           coalesce(c.transport, 0) AS transport,
           CASE WHEN coalesce(inv.invoiced, 0) > 0
                THEN round(100 * (inv.invoiced - coalesce(c.total, 0)) / inv.invoiced, 2) END AS gm,
           CASE WHEN q.quoted_price_ex_vat > 0
                THEN round(100 * (q.quoted_price_ex_vat - q.quoted_cost) / q.quoted_price_ex_vat, 2) END AS qm
    FROM core.job j
    LEFT JOIN core.quote q ON q.quote_id = j.quote_id
    LEFT JOIN (SELECT job_id, sum(amount_ex_vat) AS invoiced
                 FROM core.invoice WHERE job_id IS NOT NULL GROUP BY job_id) inv ON inv.job_id = j.job_id
    LEFT JOIN (SELECT l.job_id,
                      sum(l.cost_amount) AS total,
                      sum(l.cost_amount) FILTER (WHERE cc.cost_category_name = 'Equipment') AS equipment,
                      sum(l.cost_amount) FILTER (WHERE cc.cost_category_name = 'Installation labour') AS installation,
                      sum(l.cost_amount) FILTER (WHERE cc.cost_category_name = 'Programming and commissioning labour') AS commissioning,
                      sum(l.cost_amount) FILTER (WHERE cc.cost_category_name = 'Subcontractor') AS subcontractor,
                      sum(l.cost_amount) FILTER (WHERE cc.cost_category_name = 'Transport and logistics') AS transport
                 FROM core.job_cost_line l
                 JOIN core.cost_category cc ON cc.cost_category_id = l.cost_category_id
                GROUP BY l.job_id) c ON c.job_id = j.job_id
) z;

INSERT INTO mart.fact_quote
    (quote_key, quote_number, quote_date_key, decision_date_key, customer_key, division_key, office_key, job_key,
     status, is_won, is_closed, days_to_decide, quoted_price_ex_vat, quoted_cost, quoted_margin_pct)
SELECT q.quote_id, q.quote_number, to_char(q.quote_date, 'YYYYMMDD')::int,
       coalesce(to_char(q.decision_date, 'YYYYMMDD')::int, 0), q.customer_id, dv.division_key, q.office_id,
       coalesce(j.job_id, 0), q.status, q.status = 'won', q.status IN ('won', 'lost', 'expired'),
       q.decision_date - q.quote_date, q.quoted_price_ex_vat, q.quoted_cost,
       CASE WHEN q.quoted_price_ex_vat > 0
            THEN round(100 * (q.quoted_price_ex_vat - q.quoted_cost) / q.quoted_price_ex_vat, 2) END
FROM core.quote q
JOIN mart.dim_division dv ON dv.division_code = q.division
LEFT JOIN core.job j ON j.quote_id = q.quote_id;

INSERT INTO mart.fact_sales_line
    (sales_line_key, order_number, order_date_key, customer_key, office_key, product_key, order_status,
     quantity, unit_price_ex_vat, unit_cost, revenue, cost, gross_margin)
SELECT l.sales_order_line_id, so.order_number, to_char(so.order_date, 'YYYYMMDD')::int, so.customer_id,
       so.office_id, l.product_id, so.status, l.quantity, l.unit_price_ex_vat, l.unit_cost,
       l.line_revenue, l.line_cost, l.line_revenue - l.line_cost
FROM core.sales_order_line l
JOIN core.sales_order so ON so.sales_order_id = l.sales_order_id;

INSERT INTO mart.fact_stock_movement
    (stock_movement_key, date_key, product_key, movement_type, quantity_change, unit_cost, movement_value, balance_after)
SELECT m.stock_movement_id, to_char(m.movement_date, 'YYYYMMDD')::int, m.product_id, m.movement_type,
       m.quantity_change, m.unit_cost, m.quantity_change * m.unit_cost,
       sum(m.quantity_change) OVER (PARTITION BY m.product_id
                                    ORDER BY m.movement_date, m.quantity_change DESC, m.stock_movement_id
                                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)::int
FROM core.stock_movement m;

INSERT INTO mart.fact_maintenance
    (maintenance_key, date_key, asset_key, event_type, cost_amount, days_out_of_service, booking_number)
SELECT m.maintenance_event_id, to_char(m.event_date, 'YYYYMMDD')::int, m.asset_id, m.event_type,
       m.cost_amount, m.days_out_of_service, rb.booking_number
FROM core.maintenance_event m
LEFT JOIN core.rental_booking rb ON rb.rental_booking_id = m.rental_booking_id;

-- One row per asset per day of its life inside the reporting window
INSERT INTO mart.fact_asset_day (asset_key, date_key, bookings_count, on_hire, rental_revenue, out_of_service)
SELECT a.asset_id, d.date_key,
       coalesce(b.n, 0)::int,
       CASE WHEN coalesce(b.n, 0) > 0 THEN 1 ELSE 0 END,
       coalesce(b.revenue, 0),
       CASE WHEN o.asset_id IS NOT NULL THEN 1 ELSE 0 END
FROM core.asset a
CROSS JOIN mart.report_info ri
JOIN mart.dim_date d
  ON d.full_date BETWEEN GREATEST(a.purchase_date, ri.history_start)
                     AND LEAST(coalesce(a.retired_date, ri.as_of_date), ri.as_of_date)
LEFT JOIN (SELECT l.asset_id, gs::date AS day, count(*) AS n, sum(l.daily_rate_ex_vat) AS revenue
             FROM core.rental_booking_line l
             JOIN core.rental_booking rb ON rb.rental_booking_id = l.rental_booking_id
            CROSS JOIN LATERAL generate_series(rb.start_date::timestamp, rb.end_date::timestamp, INTERVAL '1 day') AS gs
            GROUP BY l.asset_id, gs::date) b ON b.asset_id = a.asset_id AND b.day = d.full_date
LEFT JOIN (SELECT DISTINCT m.asset_id, gs::date AS day
             FROM core.maintenance_event m
            CROSS JOIN LATERAL generate_series((m.event_date + 1)::timestamp,
                                               (m.event_date + m.days_out_of_service)::timestamp,
                                               INTERVAL '1 day') AS gs
            WHERE m.days_out_of_service > 0) o ON o.asset_id = a.asset_id AND o.day = d.full_date;

-- Step 5: indexes on the columns most often used to filter and join
CREATE INDEX ix_fact_invoice_customer ON mart.fact_invoice (customer_key);
CREATE INDEX ix_fact_invoice_date     ON mart.fact_invoice (invoice_date_key);
CREATE INDEX ix_fact_invoice_division ON mart.fact_invoice (division_key);
CREATE INDEX ix_fact_alloc_invoice    ON mart.fact_payment_allocation (invoice_key);
CREATE INDEX ix_fact_alloc_customer   ON mart.fact_payment_allocation (customer_key);
CREATE INDEX ix_fact_jobcost_job      ON mart.fact_job_cost_line (job_key);
CREATE INDEX ix_fact_quote_customer   ON mart.fact_quote (customer_key);
CREATE INDEX ix_fact_quote_division   ON mart.fact_quote (division_key);
CREATE INDEX ix_fact_sales_product    ON mart.fact_sales_line (product_key);
CREATE INDEX ix_fact_sales_customer   ON mart.fact_sales_line (customer_key);
CREATE INDEX ix_fact_stock_product    ON mart.fact_stock_movement (product_key, date_key);
CREATE INDEX ix_fact_maint_asset      ON mart.fact_maintenance (asset_key);
CREATE INDEX ix_fact_assetday_date    ON mart.fact_asset_day (date_key);

COMMIT;

-- Step 6: let PostgreSQL learn the size of the new tables
ANALYZE;

-- Step 7: checks. One result table; every row should read PASS.
SELECT what_we_check, expected, actual,
       CASE WHEN expected = actual THEN 'PASS' ELSE 'FAIL' END AS result
FROM (
    SELECT 1 AS n, 'Tables in the mart schema (8 dimensions, 9 facts, 1 information table)' AS what_we_check,
           '18' AS expected,
           (SELECT count(*) FROM information_schema.tables
             WHERE table_schema = 'mart' AND table_type = 'BASE TABLE')::text AS actual
    UNION ALL
    SELECT 2, 'Dimensions whose row count differs from the source (should be none; 8 compared)', '0',
           (SELECT count(*) FROM (
                SELECT (SELECT count(*) FROM mart.dim_customer) AS m, (SELECT count(*) FROM core.customer) AS c
                UNION ALL SELECT (SELECT count(*) FROM mart.dim_office), (SELECT count(*) FROM core.office)
                UNION ALL SELECT (SELECT count(*) FROM mart.dim_division), 3
                UNION ALL SELECT (SELECT count(*) FROM mart.dim_product), (SELECT count(*) FROM core.product)
                UNION ALL SELECT (SELECT count(*) FROM mart.dim_asset), (SELECT count(*) FROM core.asset)
                UNION ALL SELECT (SELECT count(*) FROM mart.dim_job), (SELECT count(*) FROM core.job) + 1
                UNION ALL SELECT (SELECT count(*) FROM mart.dim_cost_category), (SELECT count(*) FROM core.cost_category)
                UNION ALL SELECT (SELECT count(*) FROM mart.dim_date), (DATE '2026-12-31' - DATE '2019-01-01') + 2
            ) x WHERE x.m <> x.c)::text
    UNION ALL
    SELECT 3, 'Facts whose row count differs from the source (should be none; 8 compared)', '0',
           (SELECT count(*) FROM (
                SELECT (SELECT count(*) FROM mart.fact_invoice) AS m, (SELECT count(*) FROM core.invoice) AS c
                UNION ALL SELECT (SELECT count(*) FROM mart.fact_payment_allocation), (SELECT count(*) FROM core.payment_allocation)
                UNION ALL SELECT (SELECT count(*) FROM mart.fact_job_margin), (SELECT count(*) FROM core.job)
                UNION ALL SELECT (SELECT count(*) FROM mart.fact_job_cost_line), (SELECT count(*) FROM core.job_cost_line)
                UNION ALL SELECT (SELECT count(*) FROM mart.fact_quote), (SELECT count(*) FROM core.quote)
                UNION ALL SELECT (SELECT count(*) FROM mart.fact_sales_line), (SELECT count(*) FROM core.sales_order_line)
                UNION ALL SELECT (SELECT count(*) FROM mart.fact_stock_movement), (SELECT count(*) FROM core.stock_movement)
                UNION ALL SELECT (SELECT count(*) FROM mart.fact_maintenance), (SELECT count(*) FROM core.maintenance_event)
            ) y WHERE y.m <> y.c)::text
    UNION ALL
    SELECT 4, 'Money: invoiced before VAT, mart equals core (KES)',
           (SELECT round(sum(amount_ex_vat), 2)::text FROM core.invoice),
           (SELECT round(sum(amount_ex_vat), 2)::text FROM mart.fact_invoice)
    UNION ALL
    SELECT 5, 'Money: amount paid on invoices, mart equals the allocations in core (KES)',
           (SELECT round(sum(allocated_amount), 2)::text FROM core.payment_allocation),
           (SELECT round(sum(paid_amount), 2)::text FROM mart.fact_invoice)
    UNION ALL
    SELECT 6, 'Money: outstanding at the as-of date equals invoiced including VAT minus allocated (KES)',
           (SELECT round((SELECT sum(total_amount) FROM core.invoice) - (SELECT sum(allocated_amount) FROM core.payment_allocation), 2)::text),
           (SELECT round(sum(outstanding_amount), 2)::text FROM mart.fact_invoice)
    UNION ALL
    SELECT 7, 'Money: allocations in the payment fact equal core (KES)',
           (SELECT round(sum(allocated_amount), 2)::text FROM core.payment_allocation),
           (SELECT round(sum(allocated_amount), 2)::text FROM mart.fact_payment_allocation)
    UNION ALL
    SELECT 8, 'Money: job cost lines, mart equals core (KES)',
           (SELECT round(sum(cost_amount), 2)::text FROM core.job_cost_line),
           (SELECT round(sum(cost_amount), 2)::text FROM mart.fact_job_cost_line)
    UNION ALL
    SELECT 9, 'No double counting: job cost in the job margin fact equals the cost lines (KES)',
           (SELECT round(sum(cost_amount), 2)::text FROM mart.fact_job_cost_line),
           (SELECT round(sum(actual_cost), 2)::text FROM mart.fact_job_margin)
    UNION ALL
    SELECT 10, 'No double counting: job billing in the job margin fact equals projects invoices (KES)',
           (SELECT round(sum(amount_ex_vat), 2)::text FROM core.invoice WHERE division = 'projects'),
           (SELECT round(sum(invoiced_ex_vat), 2)::text FROM mart.fact_job_margin)
    UNION ALL
    SELECT 11, 'Money: product sales revenue, mart equals core (KES)',
           (SELECT round(sum(line_revenue), 2)::text FROM core.sales_order_line),
           (SELECT round(sum(revenue), 2)::text FROM mart.fact_sales_line)
    UNION ALL
    SELECT 12, 'Money: quoted price of all quotes, mart equals core (KES)',
           (SELECT round(sum(quoted_price_ex_vat), 2)::text FROM core.quote),
           (SELECT round(sum(quoted_price_ex_vat), 2)::text FROM mart.fact_quote)
    UNION ALL
    SELECT 13, 'Net stock quantity, mart equals core',
           (SELECT sum(quantity_change)::text FROM core.stock_movement),
           (SELECT sum(quantity_change)::text FROM mart.fact_stock_movement)
    UNION ALL
    SELECT 14, 'Money: repair and service cost, mart equals core (KES)',
           (SELECT round(sum(cost_amount), 2)::text FROM core.maintenance_event),
           (SELECT round(sum(cost_amount), 2)::text FROM mart.fact_maintenance)
    UNION ALL
    SELECT 15, 'Money: rental revenue by asset-day equals rentals invoices before VAT (KES)',
           (SELECT round(sum(amount_ex_vat), 2)::text FROM core.invoice WHERE division = 'rentals'),
           (SELECT round(sum(rental_revenue), 2)::text FROM mart.fact_asset_day)
    UNION ALL
    SELECT 16, 'Booked asset-days in the asset-day fact equal the days booked in core',
           (SELECT sum(rb.end_date - rb.start_date + 1)::text
              FROM core.rental_booking_line l
              JOIN core.rental_booking rb ON rb.rental_booking_id = l.rental_booking_id),
           (SELECT sum(bookings_count)::text FROM mart.fact_asset_day)
    UNION ALL
    SELECT 17, 'Invoices where "projects" and "has a job" disagree (should be none)', '0',
           (SELECT count(*) FROM mart.fact_invoice WHERE (division_key = 1) <> (job_key <> 0))::text
    UNION ALL
    SELECT 18, 'Finished jobs billed for a different amount than their quoted price (should be none)', '0',
           (SELECT count(*) FROM mart.fact_job_margin
             WHERE is_finished AND abs(invoiced_ex_vat - quoted_price_ex_vat) > 0.01)::text
    UNION ALL
    SELECT 19, 'Ageing bucket contradicts the outstanding amount (should be none)', '0',
           (SELECT count(*) FROM mart.fact_invoice
             WHERE (outstanding_amount > 0.005 AND ageing_bucket = 'Paid')
                OR (outstanding_amount <= 0.005 AND ageing_bucket <> 'Paid'))::text
    UNION ALL
    SELECT 20, 'Asset-days before purchase or after retirement (should be none)', '0',
           (SELECT count(*)
              FROM mart.fact_asset_day f
              JOIN mart.dim_date d ON d.date_key = f.date_key
              JOIN mart.dim_asset a ON a.asset_key = f.asset_key
             WHERE d.full_date < a.purchase_date OR (a.retired_date IS NOT NULL AND d.full_date > a.retired_date))::text
    UNION ALL
    SELECT 21, 'Asset-days that are both on hire and out of service (should be none)', '0',
           (SELECT count(*) FROM mart.fact_asset_day WHERE on_hire = 1 AND out_of_service = 1)::text
    UNION ALL
    SELECT 22, 'Asset-days with more than one booking (planted double-bookings: register R07)',
           (SELECT central::int FROM generator.parameter WHERE parameter_id = 'R07')::text,
           (SELECT count(*) FROM mart.fact_asset_day WHERE bookings_count > 1)::text
    UNION ALL
    SELECT 23, 'Won quotes in the quote fact equal won quotes in core',
           (SELECT count(*) FROM core.quote WHERE status = 'won')::text,
           (SELECT count(*) FROM mart.fact_quote WHERE is_won)::text
    UNION ALL
    SELECT 24, 'Times a product''s stock balance fell below zero in the stock fact (should be none)', '0',
           (SELECT count(*) FROM mart.fact_stock_movement WHERE balance_after < 0)::text
) t
ORDER BY n;
