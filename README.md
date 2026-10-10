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
| Assumptions register (`docs/assumptions_register.xlsx`) | Proposed values, awaiting owner review |
| Reference data (lookup lists) | Run; row counts verified (reported) |
| Stage 5: code columns in core and 16 raw tables (`sql/03_raw/run_stage_5.sql`, includes its own check) | Written, **not yet run** |
| Data generator | Not started |
| Staging, mart, SQL analysis, tests, Power BI | Not started |

## Known limitations
- Synthetic data reflects our assumptions. It cannot discover facts about a real business.
- Gross margin only. Overheads, payroll, depreciation and tax are not modelled.
- One currency (KES). No history of changes to customers or prices.
- Generator ranges are anchored on public vendor and trade sources (mostly US and UK). See the assumptions register when it is added.

## Licence
To be decided.
