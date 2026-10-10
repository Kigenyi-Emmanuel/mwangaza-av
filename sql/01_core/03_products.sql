-- Mwangaza AV (synthetic case study)
-- Core layer, part 3: the products and stock division.
-- Run after 02_projects.sql. All money is KES, before VAT. Needs PostgreSQL 12 or newer.
--
-- Stock is tracked only through stock_movement (no purchase orders, decision D6).
-- Rules a CHECK cannot enforce across tables are tested later, not enforced here (decision D14).

CREATE TABLE core.product_category (
    product_category_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_category_name text NOT NULL UNIQUE
);

CREATE TABLE core.supplier (
    supplier_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_name  text NOT NULL UNIQUE,      -- fictional suppliers only
    country        text NOT NULL
);

CREATE TABLE core.product (
    product_id           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku                  text NOT NULL UNIQUE,
    product_name         text NOT NULL,
    product_category_id  integer NOT NULL REFERENCES core.product_category (product_category_id),
    supplier_id          integer NOT NULL REFERENCES core.supplier (supplier_id),
    list_price_ex_vat    numeric(14,2) NOT NULL CHECK (list_price_ex_vat >= 0),
    standard_cost        numeric(14,2) NOT NULL CHECK (standard_cost >= 0),
    is_active            boolean NOT NULL DEFAULT true
);
CREATE INDEX ix_product_category ON core.product (product_category_id);
CREATE INDEX ix_product_supplier ON core.product (supplier_id);

CREATE TABLE core.sales_order (
    sales_order_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_number    text NOT NULL UNIQUE,
    quote_id        integer UNIQUE REFERENCES core.quote (quote_id),   -- empty for sales with no quote
    customer_id     integer NOT NULL REFERENCES core.customer (customer_id),
    office_id       integer NOT NULL REFERENCES core.office (office_id),
    order_date      date NOT NULL,
    status          text NOT NULL CHECK (status IN ('open', 'delivered', 'cancelled'))
);
CREATE INDEX ix_sales_order_customer ON core.sales_order (customer_id);
CREATE INDEX ix_sales_order_office   ON core.sales_order (office_id);
CREATE INDEX ix_sales_order_date     ON core.sales_order (order_date);

CREATE TABLE core.sales_order_line (
    sales_order_line_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sales_order_id       integer NOT NULL REFERENCES core.sales_order (sales_order_id),
    product_id           integer NOT NULL REFERENCES core.product (product_id),
    quantity             integer NOT NULL CHECK (quantity > 0),
    unit_price_ex_vat    numeric(14,2) NOT NULL CHECK (unit_price_ex_vat >= 0),
    unit_cost            numeric(14,2) NOT NULL CHECK (unit_cost >= 0),     -- cost at the time of sale
    line_revenue         numeric(14,2) GENERATED ALWAYS AS (round(quantity * unit_price_ex_vat, 2)) STORED,
    line_cost            numeric(14,2) GENERATED ALWAYS AS (round(quantity * unit_cost, 2)) STORED,
    CONSTRAINT uq_sales_order_line UNIQUE (sales_order_id, product_id)
);
CREATE INDEX ix_sales_order_line_product ON core.sales_order_line (product_id);

-- Stock ledger: quantity_change is positive when stock comes in and negative when it goes out.
CREATE TABLE core.stock_movement (
    stock_movement_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id           integer NOT NULL REFERENCES core.product (product_id),
    movement_date        date NOT NULL,
    movement_type        text NOT NULL CHECK (movement_type IN ('purchase', 'sale', 'job_use', 'adjustment')),
    quantity_change      integer NOT NULL,
    unit_cost            numeric(14,2) NOT NULL CHECK (unit_cost >= 0),
    sales_order_line_id  integer REFERENCES core.sales_order_line (sales_order_line_id),
    job_id               integer REFERENCES core.job (job_id),
    -- The sign must match the type of movement.
    CONSTRAINT ck_stock_sign CHECK (
        (movement_type = 'purchase'              AND quantity_change > 0) OR
        (movement_type IN ('sale', 'job_use')    AND quantity_change < 0) OR
        (movement_type = 'adjustment'            AND quantity_change <> 0)
    ),
    -- A sale must point to its order line, job use must point to its job, the rest point to neither.
    CONSTRAINT ck_stock_links CHECK (
        (movement_type = 'sale'    AND sales_order_line_id IS NOT NULL AND job_id IS NULL) OR
        (movement_type = 'job_use' AND job_id IS NOT NULL AND sales_order_line_id IS NULL) OR
        (movement_type IN ('purchase', 'adjustment') AND sales_order_line_id IS NULL AND job_id IS NULL)
    )
);
CREATE INDEX ix_stock_movement_product ON core.stock_movement (product_id, movement_date);
CREATE INDEX ix_stock_movement_job     ON core.stock_movement (job_id);
CREATE INDEX ix_stock_movement_sol     ON core.stock_movement (sales_order_line_id);

-- Decision 4 from the model: a job cost line can optionally point to the product used.
-- ALTER TABLE ... ADD COLUMN only adds an empty, optional column. It does not change or remove existing data.
ALTER TABLE core.job_cost_line
    ADD COLUMN product_id integer REFERENCES core.product (product_id);
CREATE INDEX ix_job_cost_line_product ON core.job_cost_line (product_id);
