# Test log

Every stage ends with a built-in check that returns a PASS/FAIL table. The results below come from runs on
PostgreSQL 18.6 (Windows). Result tables saved as files are in `tests/results/`; the last column shows where one exists.

| Stage | Script | Check | Result | Result file saved |
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
| 11 | `sql/04_generate/run_stage_11.sql` | 11 checks | Run; result table not saved | no |
| 12 | `sql/04_generate/run_stage_12.sql` | 14 checks | All PASS | no |
| 12 (profile) | `sql/05_profile/01_raw_profile.sql` | Read-only profile of the raw layer | Run | yes: `tests/results/raw_profile_before_repair_fix.csv` |
| 12b | `sql/04_generate/run_stage_12b_rescale_repair_costs.sql` | 5 checks plus one information row | Rows 1 to 5 PASS; row 6 information | no |
| 12b (profile after) | `sql/05_profile/01_raw_profile.sql` | Read-only profile after the fix; repair and service cost 10.6 percent of rental billing | Run | yes: `tests/results/raw_profile_after_repair_fix.csv` |
| 13 | `sql/06_staging/run_stage_13.sql` | 5 checks | All PASS | no |
| 14 | `sql/06_staging/run_stage_14.sql` | 15 checks, including comparison with the answer key | All PASS | no |
| 15 | `sql/06_staging/run_stage_15.sql` | 17 checks, including answer-key and reconciliation checks | All PASS | no |
| 16 | `sql/06_staging/run_stage_16.sql` | 25 checks, including answer-key and money reconciliation checks | All PASS | no |
| 17 | `sql/07_load/run_stage_17.sql`, `run_stage_17_check_only.sql` | 18 checks | First run: error in the final check statement (`column "actual" does not exist`, a typo in the check query, since fixed). Check-only file: 18 rows, all PASS | no |

**Notes on what the checks show.** Several rows test whether random draws land inside the ranges of the assumptions
register. They show that the generator behaves as designed, not that the data is realistic. The staging and load
checks compare the cleaned data with the hidden answer key (`generator.planted_error`) and reconcile money totals.
