# Mwangaza AV: Company-Wide Analytics for an AV Integrator (Synthetic Case Study)

> **All data in this project is synthetic.** The company, customers, prices and results are invented for demonstration. Nothing here describes a real organisation, and no result should be read as a finding about any real business.

## Purpose
Show how a company-wide analytics system could work for an audio-visual integrator with three divisions: installed projects, product sales and equipment rentals. The project is a prototype built on a modelled business. It demonstrates method (data modelling, ETL, SQL, validation, reporting). It does not claim any business impact.

## Planned business questions
- Which job types and sectors drift furthest from their quoted margin?
- How old is the unpaid balance, and which customers pay slowest?
- How much of the time does each rental asset earn money, and what do repairs cost?
- Which quotes win, and which products do not sell?
- What is each customer worth across all three divisions?

## Architecture
`raw` -> `staging` -> `core` (normalised) -> `mart` (star schema) -> SQL analysis -> Power BI (3 pages)

## Tools
- **PostgreSQL 18.6** (Windows): data generation, cleaning, loading and analysis, all in SQL
- **Excel**: assumptions register (`docs/assumptions_register.xlsx`); independent cross-checks of key SQL results are planned
- **Power BI**: reporting pages on top of the star schema (planned)
- **GitHub**: version control and hosting; changes are committed through the GitHub web interface
- **AI assistance (Claude, by Anthropic)**: used as a design and coding assistant for architecture discussion, drafting SQL, test design and documentation. Every script was executed on PostgreSQL and its built-in checks were run by the author.

## Status
| Component | Status |
|---|---|
| Design (model, metrics, assumptions research) | Documented in `docs/` |
| Database and schemas script | Run on PostgreSQL 18.6 |
| Core tables: shared + projects division | Run: 8 tables present |
| Core tables: products, rentals, billing | Run on PostgreSQL 18.6 |
| Structure checks (`tests/01_core_structure_checks.sql`) | Run; passed. Output not yet saved in `tests/results` |
| Assumptions register (`docs/assumptions_register.xlsx`) | Accepted as working values (in bulk). VAT and seasonality rows still open |
| Reference data (lookup lists) | Run; row counts verified |
| Stage 5: code columns in core and 16 raw tables (`sql/03_raw/run_stage_5.sql`, includes its own check) | Run on PostgreSQL 18.6; all 3 checks passed |
| Stage 6: customers and suppliers in raw, with planted errors (`sql/04_generate/run_stage_6.sql`, includes its own check) | Run on PostgreSQL 18.6; all 8 checks passed |
| Stage 7: products and rental assets in raw (`sql/04_generate/run_stage_7.sql`, includes its own check) | Run on PostgreSQL 18.6; all 11 checks passed |
| Stage 8: projects quotes, jobs and job costs in raw (`sql/04_generate/run_stage_8.sql`, includes its own check) | Run on PostgreSQL 18.6; all 12 checks passed |
| Stage 9: products quotes, sales orders and stock movements in raw (`sql/04_generate/run_stage_9.sql`, includes its own check) | Run on PostgreSQL 18.6; all 12 checks passed |
| Stage 10: rental bookings, booked assets and repairs in raw (`sql/04_generate/run_stage_10.sql`, includes its own check) | Run on PostgreSQL 18.6; all 12 checks passed |
| Stage 11: rental quotes in raw (`sql/04_generate/run_stage_11.sql`, includes its own check) | Run on PostgreSQL 18.6 |
| Stage 12: invoices, payments and allocations in raw (`sql/04_generate/run_stage_12.sql`, includes its own check) | Run on PostgreSQL 18.6; all 14 checks passed |
| Raw data profile (`sql/05_profile/01_raw_profile.sql`, read-only) | Run; result saved in `tests/results/raw_profile_before_repair_fix.csv` |
| Stage 12b: rescale rental repair costs (`sql/04_generate/run_stage_12b_rescale_repair_costs.sql`) | Run on PostgreSQL 18.6; checks 1 to 5 passed, row 6 information. Profile after the fix saved in `tests/results/raw_profile_after_repair_fix.csv` |
| Stage 13: cleaning area (staging tables, quality-rule catalogue, issue and reject logs) (`sql/06_staging/run_stage_13.sql`, includes its own check) | Run on PostgreSQL 18.6; all 5 checks passed |
| Stage 14: clean customers, suppliers, products and assets into staging; find duplicate customers; check against the answer key (`sql/06_staging/run_stage_14.sql`, includes its own check) | Run on PostgreSQL 18.6; all 15 checks passed |
| Stage 15: clean quotes, jobs, job costs, sales orders and stock movements into staging (`sql/06_staging/run_stage_15.sql`, includes its own check) | Run on PostgreSQL 18.6; all 17 checks passed |
| Stage 16: clean rentals and billing into staging; remove duplicate invoices, fix due dates, fix oversized allocations, flag double-bookings; check against the answer key (`sql/06_staging/run_stage_16.sql`, includes its own check) | Run on PostgreSQL 18.6; all 25 checks passed |
| Stage 17: load the cleaned data into the core tables and reconcile (`sql/07_load/run_stage_17.sql`; check also in `run_stage_17_check_only.sql`) | Run on PostgreSQL 18.6. The first run's final check query had a labelling typo (fixed). The check-only file returned 18 rows, all PASS |
| NULL audit of the core tables (`sql/08_audit/01_null_audit.sql`, read-only) and `docs/null-meanings.md` | Written, **not yet run** |
| Stage 18: reporting layer, a star schema in the `mart` schema, with reconciliation checks (`sql/09_mart/run_stage_18.sql`, `docs/star-schema.md`) | Written; not yet executed |
| Test log (`docs/test-log.md`) | Written. Saved result tables are in `tests/results` (data profiles; other stages not yet saved) |
| Data generator (Stages 6 to 12b) | Done (see the stage rows) |
| SQL analysis (business questions) and Power BI pages | Not started |

## Known limitations
- Synthetic data reflects our assumptions. It cannot discover facts about a real business.
- Gross margin only. Overheads, payroll, depreciation and tax are not modelled.
- One currency (KES). No history of changes to customers or prices.
- All customer and supplier names are made up from word lists. Any match with a real organisation is coincidence.
- Generator ranges are anchored on public vendor and trade sources (mostly US and UK). See `docs/assumptions_register.xlsx`.

## Licence
To be decided.
