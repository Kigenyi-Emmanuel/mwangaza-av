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

## Architecture (proposed)
`raw` -> `staging` -> `core` (normalised) -> `mart` (star schema) -> SQL analysis -> Power BI (3 pages)

Tools: PostgreSQL (12 or newer), Excel (assumptions register and independent cross-checks), Power BI.

## Status (updated honestly as work happens)
| Component | Status |
|---|---|
| Design (model, metrics, assumptions research) | Drafted, in review |
| Database and schemas script | Run on PostgreSQL 18.6 (reported by the project owner) |
| Core tables: shared + projects division | Run: 8 tables present (list reported by the project owner) |
| Core tables: products, rentals, billing | Run on PostgreSQL 18.6 |
| Structure checks (`tests/01_core_structure_checks.sql`) | Run; reported as passed. Output not yet saved in the repo |
| Assumptions register (`docs/assumptions_register.xlsx`) | Accepted as proposed by the owner (bulk accept, not reviewed row by row). VAT and seasonality rows still open |
| Reference data (lookup lists) | Run; row counts verified (reported) |
| Stage 5: code columns in core and 16 raw tables (`sql/03_raw/run_stage_5.sql`, includes its own check) | Run on PostgreSQL 18.6; all 3 checks passed (reported by the project owner) |
| Stage 6: customers and suppliers in raw, with planted errors (`sql/04_generate/run_stage_6.sql`, includes its own check) | Run on PostgreSQL 18.6; all 8 checks passed (reported by the project owner) |
| Stage 7: products and rental assets in raw (`sql/04_generate/run_stage_7.sql`, includes its own check) | Run on PostgreSQL 18.6; all 11 checks passed (reported by the project owner) |
| Stage 8: projects quotes, jobs and job costs in raw (`sql/04_generate/run_stage_8.sql`, includes its own check) | Run on PostgreSQL 18.6; all 12 checks passed (reported by the project owner) |
| Stage 9: products quotes, sales orders and stock movements in raw (`sql/04_generate/run_stage_9.sql`, includes its own check) | Run on PostgreSQL 18.6; all 12 checks passed (reported by the project owner) |
| Stage 10: rental bookings, booked assets and repairs in raw (`sql/04_generate/run_stage_10.sql`, includes its own check) | Run on PostgreSQL 18.6; all 12 checks passed (reported by the project owner) |
| Stage 11: rental quotes in raw (`sql/04_generate/run_stage_11.sql`, includes its own check) | Run on PostgreSQL 18.6; reported as smooth by the project owner (result table not yet recorded) |
| Stage 12: invoices, payments and allocations in raw (`sql/04_generate/run_stage_12.sql`, includes its own check) | Run on PostgreSQL 18.6; all 14 checks passed (reported by the project owner) |
| Raw data profile (`sql/05_profile/01_raw_profile.sql`, read-only) | Run; result saved in `tests/results/raw_profile_before_repair_fix.csv` |
| Stage 12b: rescale rental repair costs (`sql/04_generate/run_stage_12b_rescale_repair_costs.sql`) | Run on PostgreSQL 18.6; checks 1 to 5 passed, row 6 information (reported by the project owner). Profile after the fix saved in `tests/results/raw_profile_after_repair_fix.csv` |
| Stage 13: cleaning area (staging tables, quality-rule catalogue, issue and reject logs) (`sql/06_staging/run_stage_13.sql`, includes its own check) | Run on PostgreSQL 18.6; all 5 checks passed (reported by the project owner) |
| Stage 14: clean customers, suppliers, products and assets into staging; find duplicate customers; check against the answer key (`sql/06_staging/run_stage_14.sql`, includes its own check) | Run on PostgreSQL 18.6; all 15 checks passed (reported by the project owner) |
| Stage 15: clean quotes, jobs, job costs, sales orders and stock movements into staging (`sql/06_staging/run_stage_15.sql`, includes its own check) | Run on PostgreSQL 18.6; all 17 checks passed (reported by the project owner) |
| Stage 16: clean rentals and billing into staging; remove duplicate invoices, fix due dates, fix oversized allocations, flag double-bookings; check against the answer key (`sql/06_staging/run_stage_16.sql`, includes its own check) | Run on PostgreSQL 18.6; all 25 checks passed (reported by the project owner) |
| Stage 17: load the cleaned data into the core tables and reconcile (`sql/07_load/run_stage_17.sql`; check also in `run_stage_17_check_only.sql`) | Run on PostgreSQL 18.6. The first run's final check query had a labelling typo (fixed). The check-only file returned 18 rows, all PASS (reported by the project owner) |
| NULL audit of the core tables (`sql/08_audit/01_null_audit.sql`, read-only) and `docs/null-meanings.md` | Written, **not yet run** |
| Test log (`docs/test-log.md`) | Written. Results are owner-reported; result tables not yet saved |
| Data generator | Not started |
| Staging, mart, SQL analysis, tests, Power BI | Not started |

## Known limitations
- Synthetic data reflects our assumptions. It cannot discover facts about a real business.
- Gross margin only. Overheads, payroll, depreciation and tax are not modelled.
- One currency (KES). No history of changes to customers or prices.
- All customer and supplier names are made up from word lists. Any match with a real organisation is coincidence.
- Generator ranges are anchored on public vendor and trade sources (mostly US and UK). See the assumptions register when it is added.

## Licence
To be decided.
