-- Mwangaza AV (synthetic case study)
-- Core layer, part 4: the rentals division.
-- Run after 03_products.sql. All money is KES, before VAT.
--
-- On purpose, the database does NOT stop two bookings using the same asset on the same dates
-- (decision D13). Real booking systems often allow it, and "which assets are double-booked?" is a
-- question we want to be able to ask. A booking's dates live on rental_booking; its lines inherit them.

CREATE TABLE core.asset_category (
    asset_category_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    asset_category_name  text NOT NULL UNIQUE
);

CREATE TABLE core.asset (
    asset_id             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    asset_tag            text NOT NULL UNIQUE,
    asset_name           text NOT NULL,
    asset_category_id    integer NOT NULL REFERENCES core.asset_category (asset_category_id),
    purchase_date        date NOT NULL,
    purchase_cost        numeric(14,2) NOT NULL CHECK (purchase_cost >= 0),
    daily_rate_ex_vat    numeric(14,2) NOT NULL CHECK (daily_rate_ex_vat >= 0),   -- standard rate card
    status               text NOT NULL CHECK (status IN ('active', 'in_repair', 'retired')),
    retired_date         date,
    CONSTRAINT ck_asset_retired CHECK ((status = 'retired') = (retired_date IS NOT NULL))
);
CREATE INDEX ix_asset_category ON core.asset (asset_category_id);

CREATE TABLE core.rental_booking (
    rental_booking_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_number     text NOT NULL UNIQUE,
    quote_id           integer UNIQUE REFERENCES core.quote (quote_id),   -- empty for bookings with no quote
    customer_id        integer NOT NULL REFERENCES core.customer (customer_id),
    office_id          integer NOT NULL REFERENCES core.office (office_id),
    start_date         date NOT NULL,
    end_date           date NOT NULL,
    status             text NOT NULL CHECK (status IN ('confirmed', 'completed', 'cancelled')),
    CONSTRAINT ck_booking_dates CHECK (end_date >= start_date)
);
CREATE INDEX ix_booking_customer ON core.rental_booking (customer_id);
CREATE INDEX ix_booking_office   ON core.rental_booking (office_id);
CREATE INDEX ix_booking_dates    ON core.rental_booking (start_date, end_date);

CREATE TABLE core.rental_booking_line (
    rental_booking_line_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rental_booking_id       integer NOT NULL REFERENCES core.rental_booking (rental_booking_id),
    asset_id                integer NOT NULL REFERENCES core.asset (asset_id),
    daily_rate_ex_vat       numeric(14,2) NOT NULL CHECK (daily_rate_ex_vat >= 0),   -- rate actually charged
    CONSTRAINT uq_booking_line UNIQUE (rental_booking_id, asset_id)
);
CREATE INDEX ix_booking_line_asset ON core.rental_booking_line (asset_id);

CREATE TABLE core.maintenance_event (
    maintenance_event_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    asset_id              integer NOT NULL REFERENCES core.asset (asset_id),
    event_date            date NOT NULL,
    event_type            text NOT NULL CHECK (event_type IN ('routine_service', 'damage_repair', 'loss')),
    cost_amount           numeric(14,2) NOT NULL CHECK (cost_amount >= 0),
    days_out_of_service   integer NOT NULL DEFAULT 0 CHECK (days_out_of_service >= 0),
    rental_booking_id     integer REFERENCES core.rental_booking (rental_booking_id)   -- set when damage happened on a booking
);
CREATE INDEX ix_maintenance_asset   ON core.maintenance_event (asset_id, event_date);
CREATE INDEX ix_maintenance_booking ON core.maintenance_event (rental_booking_id);
