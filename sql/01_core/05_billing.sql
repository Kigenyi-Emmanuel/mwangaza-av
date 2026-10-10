-- Mwangaza AV (synthetic case study)
-- Core layer, part 5: billing and cash, shared by all three divisions (decision D4).
-- Run after 04_rentals.sql. All money is KES.
--
-- Rules that look across rows or tables are NOT enforced here (decision D14). They are checked by
-- tests instead:
--   * an invoice's customer matches the customer of its job, sales order or booking
--   * the total allocated to an invoice never exceeds the invoice total
--   * the total allocated from a payment never exceeds the payment amount
--   * a payment and the invoice it pays belong to the same customer

CREATE TABLE core.invoice (
    invoice_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoice_number     text NOT NULL UNIQUE,
    division           text NOT NULL CHECK (division IN ('projects', 'products', 'rentals')),
    job_id             integer REFERENCES core.job (job_id),
    sales_order_id     integer REFERENCES core.sales_order (sales_order_id),
    rental_booking_id  integer REFERENCES core.rental_booking (rental_booking_id),
    customer_id        integer NOT NULL REFERENCES core.customer (customer_id),   -- kept here for convenience; tested against the source
    invoice_date       date NOT NULL,
    due_date           date NOT NULL,
    amount_ex_vat      numeric(14,2) NOT NULL CHECK (amount_ex_vat >= 0),
    vat_amount         numeric(14,2) NOT NULL DEFAULT 0 CHECK (vat_amount >= 0),
    total_amount       numeric(14,2) GENERATED ALWAYS AS (amount_ex_vat + vat_amount) STORED,
    CONSTRAINT ck_invoice_due_after_invoice CHECK (due_date >= invoice_date),
    -- Exactly one of the three sources must be filled in.
    CONSTRAINT ck_invoice_one_source CHECK (num_nonnulls(job_id, sales_order_id, rental_booking_id) = 1),
    -- The filled-in source must match the division.
    CONSTRAINT ck_invoice_division_matches_source CHECK (
        (division = 'projects' AND job_id IS NOT NULL) OR
        (division = 'products' AND sales_order_id IS NOT NULL) OR
        (division = 'rentals'  AND rental_booking_id IS NOT NULL)
    )
);
CREATE INDEX ix_invoice_job      ON core.invoice (job_id);
CREATE INDEX ix_invoice_sales    ON core.invoice (sales_order_id);
CREATE INDEX ix_invoice_booking  ON core.invoice (rental_booking_id);
CREATE INDEX ix_invoice_customer ON core.invoice (customer_id);
CREATE INDEX ix_invoice_date     ON core.invoice (invoice_date);
CREATE INDEX ix_invoice_due      ON core.invoice (due_date);

CREATE TABLE core.payment (
    payment_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payment_reference  text NOT NULL UNIQUE,
    customer_id        integer NOT NULL REFERENCES core.customer (customer_id),
    payment_date       date NOT NULL,
    amount             numeric(14,2) NOT NULL CHECK (amount > 0),
    payment_method     text NOT NULL CHECK (payment_method IN ('bank_transfer', 'mobile_money', 'cheque', 'cash'))
);
CREATE INDEX ix_payment_customer ON core.payment (customer_id);
CREATE INDEX ix_payment_date     ON core.payment (payment_date);

-- One payment can pay several invoices, and one invoice can be paid in parts.
CREATE TABLE core.payment_allocation (
    payment_allocation_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payment_id             integer NOT NULL REFERENCES core.payment (payment_id),
    invoice_id             integer NOT NULL REFERENCES core.invoice (invoice_id),
    allocated_amount       numeric(14,2) NOT NULL CHECK (allocated_amount > 0),
    CONSTRAINT uq_payment_allocation UNIQUE (payment_id, invoice_id)
);
CREATE INDEX ix_allocation_invoice ON core.payment_allocation (invoice_id);
