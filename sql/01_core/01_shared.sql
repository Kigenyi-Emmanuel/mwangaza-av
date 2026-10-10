-- Mwangaza AV (synthetic case study)
-- Core layer, part 1: tables shared by all divisions.
-- Run while connected to mwangaza_av, after 02_create_schemas.sql.
-- Needs PostgreSQL 10 or newer (identity columns). All money is KES, before VAT.

CREATE TABLE core.sector (
    sector_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sector_name  text NOT NULL UNIQUE
);

CREATE TABLE core.office (
    office_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    office_name  text NOT NULL UNIQUE,
    country      text NOT NULL
);

CREATE TABLE core.customer (
    customer_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_name       text NOT NULL UNIQUE,          -- fictional organisations only, no people
    sector_id           integer NOT NULL REFERENCES core.sector (sector_id),
    payment_terms_days  integer NOT NULL DEFAULT 30 CHECK (payment_terms_days >= 0),
    created_date        date NOT NULL
);
CREATE INDEX ix_customer_sector ON core.customer (sector_id);

CREATE TABLE core.quote (
    quote_id             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    quote_number         text NOT NULL UNIQUE,
    customer_id          integer NOT NULL REFERENCES core.customer (customer_id),
    office_id            integer NOT NULL REFERENCES core.office (office_id),
    division             text NOT NULL CHECK (division IN ('projects', 'products', 'rentals')),
    quote_date           date NOT NULL,
    decision_date        date,                          -- empty while the quote is open or expired
    status               text NOT NULL CHECK (status IN ('open', 'won', 'lost', 'expired')),
    quoted_price_ex_vat  numeric(14,2) NOT NULL CHECK (quoted_price_ex_vat >= 0),
    quoted_cost          numeric(14,2) NOT NULL CHECK (quoted_cost >= 0),
    CONSTRAINT ck_quote_decision_after_quote
        CHECK (decision_date IS NULL OR decision_date >= quote_date),
    -- A decision date must exist exactly when the quote is won or lost.
    CONSTRAINT ck_quote_status_matches_decision
        CHECK ((status IN ('won', 'lost')) = (decision_date IS NOT NULL))
);
CREATE INDEX ix_quote_customer ON core.quote (customer_id);
CREATE INDEX ix_quote_office   ON core.quote (office_id);
CREATE INDEX ix_quote_date     ON core.quote (quote_date);
