-- Mwangaza AV (synthetic case study)
-- STAGE 12b: bring rental repair costs down to a believable size. STATUS: run on PostgreSQL 18.6; the project owner reports rows 1 to 5 PASS and row 6 information only (repair and service cost 10.6 percent of rental billing; profile saved in tests/results).
-- Run it ONCE, in the mwangaza_av database, only if you AGREE with the change (see the explanation below).
--
-- Why: the data profile after Stage 12 showed repair and service costs equal to 24.7 percent of rental
-- billing, and about 60 percent of the fleet's purchase price over three years. That is too high for a
-- rental business, and a person from the industry would notice. The cause is my assumption in register
-- row R05 (cost of one damage repair as a share of the asset's price: 2 to 25 percent, central 8 percent),
-- combined with about 7 damage events per asset over three years. It is not from any source.
--
-- What it does, in plain words:
--   1. Stops if it was already run, or if there are no maintenance events.
--   2. Saves a copy of every repair cost first (generator.maintenance_cost_backup), so this can be undone.
--   3. Multiplies the cost of every DAMAGE repair by 0.4. Routine services are not changed.
--   4. Updates register row R05 in the answer key to match: 0.8 percent / 3.3 percent / 10 percent.
--   5. Shows one result table. Every row should say PASS.
--
-- What changes: only the cost_amount column of raw.maintenance_event (damage repairs only), and one row of
-- generator.parameter. Nothing is deleted.
-- Expected effect: repair and service cost falls from about 24.7 percent to about 10 percent of rental
-- billing. The 10 percent is MY JUDGEMENT of a believable level, not a verified industry figure.
--
-- TO UNDO (run these two statements):
--   UPDATE raw.maintenance_event m SET cost_amount = b.old_cost_amount
--     FROM generator.maintenance_cost_backup b WHERE b.raw_row_id = m.raw_row_id;
--   UPDATE generator.parameter SET low = 0.02, central = 0.08, high = 0.25 WHERE parameter_id = 'R05';

BEGIN;

-- Step 1: safety checks
DO $$
BEGIN
    IF (SELECT count(*) FROM raw.maintenance_event) = 0 THEN
        RAISE EXCEPTION 'Stop: there are no maintenance events. Nothing was changed.';
    END IF;
    IF to_regclass('generator.maintenance_cost_backup') IS NOT NULL THEN
        RAISE EXCEPTION 'Stop: this fix was already run (the backup exists). Nothing was changed.';
    END IF;
END $$;

-- Step 2: keep a copy of the old costs
CREATE TABLE generator.maintenance_cost_backup AS
SELECT raw_row_id, event_type, cost_amount AS old_cost_amount
FROM raw.maintenance_event;

-- Step 3: scale damage repairs to 40 percent of their old cost
UPDATE raw.maintenance_event
SET cost_amount = round(cost_amount::numeric * 0.4, 2)::text
WHERE event_type = 'damage_repair';

-- Step 4: keep the answer key in line with the new size
UPDATE generator.parameter
SET low = 0.008, central = 0.033, high = 0.10
WHERE parameter_id = 'R05';

COMMIT;

-- Step 5: the check. One result table. Every row should say PASS.
SELECT what_we_check, expected, actual,
       CASE WHEN expected = actual THEN 'PASS' ELSE 'FAIL' END AS result
FROM (
    SELECT 1 AS n, 'Backup rows equal maintenance rows' AS what_we_check,
           (SELECT count(*) FROM raw.maintenance_event)::text AS expected,
           (SELECT count(*) FROM generator.maintenance_cost_backup)::text AS actual
    UNION ALL
    SELECT 2, 'Damage-repair costs are now 40 percent of the old total (within 0.1 percent)', 'yes',
           (SELECT CASE WHEN abs(sum(m.cost_amount::numeric) / nullif(sum(b.old_cost_amount::numeric), 0) - 0.4) < 0.001
                        THEN 'yes' ELSE 'no' END
              FROM raw.maintenance_event m
              JOIN generator.maintenance_cost_backup b ON b.raw_row_id = m.raw_row_id
             WHERE m.event_type = 'damage_repair')
    UNION ALL
    SELECT 3, 'Routine service costs that changed (should be none)', '0',
           (SELECT count(*)
              FROM raw.maintenance_event m
              JOIN generator.maintenance_cost_backup b ON b.raw_row_id = m.raw_row_id
             WHERE m.event_type <> 'damage_repair' AND m.cost_amount <> b.old_cost_amount)::text
    UNION ALL
    SELECT 4, 'Register row R05 now holds 0.008 / 0.033 / 0.1', 'yes',
           (SELECT CASE WHEN low = 0.008 AND central = 0.033 AND high = 0.10 THEN 'yes' ELSE 'no' END
              FROM generator.parameter WHERE parameter_id = 'R05')
    UNION ALL
    SELECT 5, 'Repair and service cost is between 7 and 14 percent of rental billing (my expectation: about 10)', 'yes',
           (SELECT CASE WHEN s BETWEEN 7 AND 14 THEN 'yes' ELSE 'no' END
              FROM (SELECT 100 * (SELECT sum(cost_amount::numeric) FROM raw.maintenance_event)
                          / (SELECT sum(amount_ex_vat) FROM generator.invoice_profile WHERE division = 'rentals') AS s) q)
    UNION ALL
    SELECT 6, 'Information only: repair and service cost as a percent of rental billing now',
           (SELECT round(100 * (SELECT sum(cost_amount::numeric) FROM raw.maintenance_event)
                       / (SELECT sum(amount_ex_vat) FROM generator.invoice_profile WHERE division = 'rentals'), 1)::text),
           (SELECT round(100 * (SELECT sum(cost_amount::numeric) FROM raw.maintenance_event)
                       / (SELECT sum(amount_ex_vat) FROM generator.invoice_profile WHERE division = 'rentals'), 1)::text)
) t
ORDER BY n;
