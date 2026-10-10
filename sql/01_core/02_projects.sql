-- Mwangaza AV (synthetic case study)
-- Core layer, part 2: the projects division (installed jobs and their costs).
-- Run after 01_shared.sql. All money is KES, before VAT.
--
-- Needs PostgreSQL 12 or newer (stored generated column).
-- Rule a CHECK cannot enforce: a job's quote must have division = 'projects'.
-- We will test that later with a validation query instead.

CREATE TABLE core.job_type (
    job_type_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    job_type_name  text NOT NULL UNIQUE
);

CREATE TABLE core.cost_category (
    cost_category_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cost_category_name  text NOT NULL UNIQUE
);

CREATE TABLE core.job (
    job_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    job_number   text NOT NULL UNIQUE,
    quote_id     integer UNIQUE REFERENCES core.quote (quote_id),  -- one job per quote; empty for jobs with no quote
    customer_id  integer NOT NULL REFERENCES core.customer (customer_id),
    office_id    integer NOT NULL REFERENCES core.office (office_id),
    job_type_id  integer NOT NULL REFERENCES core.job_type (job_type_id),
    start_date   date NOT NULL,
    end_date     date,
    status       text NOT NULL CHECK (status IN ('in_progress', 'completed', 'cancelled')),
    CONSTRAINT ck_job_dates       CHECK (end_date IS NULL OR end_date >= start_date),
    CONSTRAINT ck_job_status_end  CHECK (status <> 'completed' OR end_date IS NOT NULL)
);
CREATE INDEX ix_job_customer ON core.job (customer_id);
CREATE INDEX ix_job_office   ON core.job (office_id);
CREATE INDEX ix_job_type     ON core.job (job_type_id);

CREATE TABLE core.job_cost_line (
    job_cost_line_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    job_id            integer NOT NULL REFERENCES core.job (job_id),
    cost_category_id  integer NOT NULL REFERENCES core.cost_category (cost_category_id),
    cost_date         date NOT NULL,
    description       text,
    quantity          numeric(12,2) NOT NULL CHECK (quantity > 0),
    unit_cost         numeric(14,2) NOT NULL CHECK (unit_cost >= 0),
    cost_amount       numeric(14,2) GENERATED ALWAYS AS (round(quantity * unit_cost, 2)) STORED
);
CREATE INDEX ix_job_cost_line_job      ON core.job_cost_line (job_id);
CREATE INDEX ix_job_cost_line_category ON core.job_cost_line (cost_category_id);
-- Not modelled yet: credits or returns (negative costs). Listed as a known limitation.
