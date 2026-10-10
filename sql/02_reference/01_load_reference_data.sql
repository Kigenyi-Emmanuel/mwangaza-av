-- Mwangaza AV (synthetic case study)
-- Stage 4: load the small lookup lists (reference data) straight into the core layer.
-- Run while connected to mwangaza_av, after all core scripts.
-- STATUS: run on PostgreSQL 18.6 (reported by the project owner). All values are synthetic and generic.
--
-- Everything sits inside one transaction (BEGIN ... COMMIT), so it is all or nothing.
-- If any line fails, nothing from this script is saved.
-- Running it a second time fails on the UNIQUE rules and adds nothing (no duplicates).
-- Edit the lists below BEFORE running if you want different names.

BEGIN;

INSERT INTO core.sector (sector_name) VALUES
    ('Hospitality'),
    ('Corporate'),
    ('Education'),
    ('Government'),
    ('Non-profit'),
    ('Events and media'),
    ('Healthcare');

INSERT INTO core.office (office_name, country) VALUES
    ('Nairobi', 'Kenya'),
    ('Mombasa', 'Kenya');

INSERT INTO core.job_type (job_type_name) VALUES
    ('Conference room installation'),
    ('Public address and background audio'),
    ('Video wall and display installation'),
    ('Control room installation'),
    ('Auditorium and hall fit-out'),
    ('Stage lighting installation'),
    ('Smart office and automation'),
    ('Maintenance and support contract');

-- Labour is split in two so we can later see whether programming and commissioning
-- is where estimates go wrong (planted problem X06).
INSERT INTO core.cost_category (cost_category_name) VALUES
    ('Equipment'),
    ('Installation labour'),
    ('Programming and commissioning labour'),
    ('Subcontractor'),
    ('Transport and logistics');

INSERT INTO core.product_category (product_category_name) VALUES
    ('Microphones'),
    ('Loudspeakers and amplifiers'),
    ('Mixers and processors'),
    ('Displays and projectors'),
    ('Video conferencing'),
    ('Cables and connectors'),
    ('Lighting fixtures'),
    ('Control and automation devices');

INSERT INTO core.asset_category (asset_category_name) VALUES
    ('Conference audio'),
    ('Sound reinforcement'),
    ('Projection and screens'),
    ('Stage lighting'),
    ('LED displays'),
    ('Video and streaming');

COMMIT;
