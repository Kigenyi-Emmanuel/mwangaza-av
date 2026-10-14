# Test log

**How to read this.** Every stage of this project ends with a check that returns a PASS/FAIL table. All
results below were **reported by the project owner**. The AI assistant helping with this project cannot run
PostgreSQL and has not run any of this SQL. The result tables themselves have **not** been saved in this
repo yet, so these entries are reports, not recorded evidence.

**How to turn a report into evidence:** after running a stage, save its result table (in pgAdmin, use the
download / "Save results to file" button in the results toolbar; the name may differ in your version) into
`tests/results/` as `stage-NN.csv`, and change the "Evidence saved" column to "yes".

Environment: PostgreSQL 18.6 on Windows. Seed: see register row G03. History window 2023-10-01 to 2026-09-30.

| Stage | Script | Check | Result as reported | Evidence saved |
|---|---|---|---|---|
| 1 | `sql/00_setup`, `sql/01_core/01-02` | 8 core tables exist | 8 tables listed | no |
| 2 | `sql/01_core/03-05`, `tests/01_core_structure_checks.sql` | 22 core tables; one rule test | Passed | no |
| 4 | `sql/02_reference/01_load_reference_data.sql`, `tests/02_reference_data_checks.sql` | Row counts 7, 2, 8, 5, 8, 6 | Matched | no |
| 5 | `sql/03_raw/run_stage_5.sql` | 3 checks | All PASS | no |
| 6 | `sql/04_generate/run_stage_6.sql` | 8 checks | All PASS | no |
| 7 | `sql/04_generate/run_stage_7.sql` | 11 checks | All PASS | no |
| 8 | `sql/04_generate/run_stage_8.sql` | 12 checks | All PASS | no |
| 9 | `sql/04_generate/run_stage_9.sql` | 12 checks | All PASS | no |
| 10 | `sql/04_generate/run_stage_10.sql` | 12 checks | All PASS | no |
| 11 | `sql/04_generate/run_stage_11.sql` | 11 checks | Reported as "smooth"; result table not shown | no |
| 12 | `sql/04_generate/run_stage_12.sql` | 14 checks | All PASS | no |

Known limits of these checks: several rows test whether random draws land inside the assumptions-register
ranges. They show the generator behaves as designed. They do not show the data is realistic.
| 12 (profile) | `sql/05_profile/01_raw_profile.sql` | Read-only profile of the raw layer | Run; table pasted by the owner | yes: `tests/results/raw_profile_before_repair_fix.csv` |
| 12b | `sql/04_generate/run_stage_12b_rescale_repair_costs.sql` | 5 checks plus one information row | Rows 1 to 5 PASS (reported); row 6 information | no (but the profile after the fix is saved) |
| 12b (profile after) | `sql/05_profile/01_raw_profile.sql` | Read-only profile after the fix | Run; table pasted by the owner. Repair and service cost 10.6 percent of rental billing | yes: `tests/results/raw_profile_after_repair_fix.csv` |
