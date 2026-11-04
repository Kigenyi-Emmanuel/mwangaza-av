# Report and recommendations

**Scope.** A fictional audio-visual company with three divisions (projects, products, rentals). The data is synthetic and
covers 1 October 2023 to 30 September 2026. Amounts are in KES before VAT unless stated. Evidence: `docs/findings.md`, the
18 views in the `analysis` schema and the three Power BI pages. Figures marked *calculated* are arithmetic on those results.
The benefits below are potential benefits with their reasoning, not forecasts: nothing has been measured in a real business.

## 1. Summary
- Billing over the three years is KES 1,618.5m: rentals 54.6 percent, products 23.5 percent, projects 21.9 percent.
- Finished projects earned a margin of 26.6 percent. One job type, auditorium and hall fit-out, lost 5.4 percent against a
  quoted 36.9 percent. Without it the margin would be about 34.3 percent (calculated).
- The unpaid balance is KES 71.9m including VAT. 65.6 percent is not yet due; 34.4 percent is overdue, mostly in rentals.
- Six customers pay about 90 days after the due date.
- Eight rental assets were on hire under 10 percent of the time and cost KES 11.05m to repair and service against KES 2.09m
  of revenue.
- 48 of 147 customers buy from all three divisions; 91 rent equipment but have never been billed for a project.

## 2. How the results were produced
Synthetic data was generated with planted problems and an answer key, loaded into a raw layer, cleaned by 13 written rules,
loaded into normalised core tables, reshaped into a star schema, and queried through 18 documented views. Every stage ends
with built-in checks; totals reconcile to the cent between layers, and the cleaning found the planted problems without false
alarms. Details: `docs/test-log.md`, `docs/data-quality-rules.md`, `docs/star-schema.md`.

## 3. Recommendations in priority order
Value, effort and confidence are judgements, not measurements.

| ID | Recommendation | Value | Effort | Confidence | Findings |
|---|---|---|---|---|---|
| R1 | Review and re-price auditorium and hall fit-out jobs | High | Low | High | F1 |
| R2 | Estimate commissioning labour more carefully on control-room and smart-office jobs | Medium | Medium | Medium | F2 |
| R3 | Focus collection on overdue rental invoices and review the six slowest accounts | High | Low | High | F4, F5 |
| R4 | Fix master data: required fields, unique customer codes, duplicate checks | Medium | Low | High | F5, data cleaning |
| R5 | Review the eight idle assets for retirement or redeployment | Medium | Low | High | F7 |
| R6 | Decide rental purchases on revenue per asset-day; add an overlap check to bookings | Medium | Medium | Medium | F8, F10 |
| R7 | Stop reordering and discount the slowest-moving products | Medium | Low | Medium (pending validation) | F13 |
| R8 | Cross-sell projects to rental customers, starting with good payers | Medium | Medium | Medium | F15 |
| R9 | Track and shorten quote turnaround | Low to medium | Medium | Low (pending validation) | F12 |

**R1. Review and re-price auditorium and hall fit-out jobs.**
*Evidence:* 11 finished jobs, 68.27m billed, actual margin -5.4 percent against 36.9 percent quoted; equipment is 45.7 percent
of cost against 33 to 34 percent elsewhere. *Decision:* how this job type is quoted and scoped. *Benefit and reasoning:* the
gap between this type and the other types (34.3 percent) on 68.3m billed is about KES 27m of gross profit over three years
(calculated); only part of it would be recoverable, and how much is unknown. *Costs and risks:* some work may be lost if
prices rise; review effort. *Implementation:* review the 11 jobs line by line, correct the equipment allowance in the
quoting template, add a margin check at quote approval. *Measure:* actual margin and quoted-versus-actual variance by job
type each quarter. *Further evidence needed:* why equipment cost is high (price, scope or recording).

**R2. Estimate commissioning labour more carefully.**
*Evidence:* commissioning labour is 21.7 and 21.5 percent of cost on control-room and smart-office jobs against 18.1 to 18.9
percent elsewhere; margin falls 4.6 and 3.1 points below quote. *Benefit and reasoning:* each point of margin on these two
types is worth about KES 1.05m over the period (calculated from 104.7m billed). *Implementation:* record quoted hours per
cost category on every quote, so overruns can be measured against the quote. *Measure:* margin variance on these types.
*Limit:* quotes currently hold one total cost, so the overrun is inferred, not measured.

**R3. Focus collection on overdue rental invoices and review the six slowest accounts.**
*Evidence:* KES 24.7m is overdue, 18.0m of it in rentals; six customers pay 87.5 to 98.9 days after the due date. *Benefit
and reasoning:* each day of average collection delay ties up about KES 1.5m of cash (calculated: 1,618.5m billed over 1,096
days); financing cost has not been calculated. *Implementation:* a weekly overdue list by customer, a reminder on the due
date, a credit-terms review for the six accounts. *Measure:* overdue share (34.4 percent) and weighted days after due.
*Risk:* strain on customer relationships. *Further evidence needed:* whether late payment reflects disputes.

**R4. Fix master data.**
*Evidence:* five customers had no sector (the slowest payer was one of them), six customers were entered twice, and
duplicate invoices and impossible due dates appeared in the source data. *Implementation:* required fields, a unique
customer code, a duplicate check on entry for customers and invoices. *Measure:* blank fields and duplicates found each
month. *Benefit:* reliable reports; low cost.

**R5. Review the eight idle assets.**
*Evidence:* 1.4 to 7.6 percent on hire; together KES 2.09m revenue and KES 11.05m repair and service cost, which is 11.8
percent of all repair cost and 0.24 percent of revenue. *Implementation:* check purchase cost and resale value, decide
whether to retire, sell or redeploy. *Measure:* repair cost as a share of revenue per asset (portfolio: 10.6 percent).
*Limit:* repairs are set against revenue only. *Further evidence needed:* purchase cost, type of damage, demand.

**R6. Decide rental purchases on revenue per asset-day and add a booking overlap check.**
*Evidence:* LED displays earn 227.4m at 43.1 percent on hire; conference audio earns 41.9m at 57.6 percent. 15 booking
overlaps on 14 assets, each one day. *Measure:* revenue per asset-day by category; overlaps per quarter.

**R7. Stop reordering and discount the slowest-moving products.**
*Evidence:* two of the eight slowest products never sold (one holds KES 1.38m of stock); six more last sold 555 to 864 days
ago and hold about KES 3.2m (calculated). Exact totals await the validation query (F13). *Measure:* stock value without a
sale in 12 months.

**R8. Cross-sell projects to rental customers.**
*Evidence:* 91 of 147 customers rent but have never had a project; the largest rents KES 27.5m. *Caution:* one of the
larger ones is also among the slowest payers, so check payment record first. *Measure:* customers using two or more
divisions.

**R9. Track and shorten quote turnaround.**
*Evidence:* pooled win rate falls from about 75 percent to 62.8 percent for quotes decided after 45 days. This is an
association, and the split by division is pending (F12). Treat as a hypothesis.

## 4. Limitations
- Synthetic data: no result describes a real business. Some patterns were planted to test the method, and some results are
  artefacts of how the data was generated (labelled in `docs/findings.md`).
- Rental costs are not recorded per booking, so rental margin cannot be calculated.
- Recommendations R7 and R9, and findings F3, F9, F11 and F12, wait for `sql/10_analysis/findings_validation.sql`.

## 5. Next step: a pilot on real data
A small pilot on 12 months of invoices, payments and job costs, under a written agreement that sets the purpose, the data
supplied, how it is stored and who may see it, with personal data removed or pseudonymised before analysis and no upload to
services the company has not approved. The deliverable would be a reconciled dashboard and a findings note. Success criteria
are agreed in advance, for example that the totals reconcile to the accounting ledger and that management finds at least
one decision-relevant result.
