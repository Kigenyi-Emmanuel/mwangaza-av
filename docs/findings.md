# Findings

All figures come from the synthetic data of this case study. They describe a fictional company and say nothing about any
real organisation. The aim is to show the kind of answers a company-wide analytics system can give, and to be exact about
how far each answer can be trusted.

**Source.** The 18 views in the `analysis` schema (`docs/analysis-questions.md`). The headline results of the run are
saved in `tests/results/headline_summary.csv`. Figures marked *calculated* are arithmetic on the rounded values of that
table. Findings marked *to verify* have a matching query in `sql/10_analysis/findings_validation.sql`.

**How each finding is labelled**
- **Planted**: a pattern deliberately built into the data to test the method. Finding it shows the method works.
- **Emergent**: a pattern that follows from how the data was built, without being planted directly.
- **Artefact**: a result produced by how the data was generated or sliced. It is not a business insight and must not be
  presented as one.

## Summary

| # | Finding | Label | Page |
|---|---|---|---|
| F1 | One job type (auditorium and hall fit-out) loses money and pulls total margin down by about 7.7 points | Planted | 1 |
| F2 | Commissioning labour takes a larger share of cost on control rooms and smart offices | Planted | 1 |
| F3 | Sector margin differences probably reflect job mix, not sector behaviour | To verify | 1 |
| F4 | About two thirds of the unpaid balance is not yet due; overdue money sits mostly in rentals | Emergent | 1 |
| F5 | A handful of customers pay about 90 days after the due date | Planted and emergent | 1 |
| F6 | No trend in payment speed; the first quarter is an artefact; the second quarter is slowest every year, unexplained | Artefact and open question | 1 |
| F7 | Eight assets are on hire under 10 percent of the time and cost far more to repair than they earn | Planted | 2 |
| F8 | Revenue depends on daily rate as much as on utilisation | Emergent | 2 |
| F9 | Event kit carries the heaviest repair burden, partly because of the idle assets | To verify | 2 |
| F10 | Double-booking is rare and minor | Planted | 2 |
| F11 | Win rates differ by division; size effects are noise or artefacts | Artefact | 3 |
| F12 | Quotes that take over 45 days to decide win less often | Planted (projects), pooled view | 3 |
| F13 | The slowest-moving products tie up stock | Planted and emergent | 3 |
| F14 | Billing is spread across customers: 43 of 147 make 80 percent | Emergent | 3 |
| F15 | Large customers buy from all three divisions; most rental customers have never had a project | Emergent | 3 |
| F16 | Quote decision times | Artefact | 3 |

## Page 1: profitability and cash

**F1. One job type loses money and pulls total margin down (planted).**
Auditorium and hall fit-out: 11 finished jobs, 68.27m billed, quoted margin 36.9 percent, actual margin -5.4 percent (Q01).
The other seven job types earn between 31.0 and 36.1 percent. Calculated: the overall margin of finished jobs is 26.6
percent; without this job type it would be about 34.3 percent, so this one type costs about 7.7 points of margin, a gross
loss of roughly KES 3.7m on 68m billed. The cause is equipment: it makes up 45.7 percent of this type's cost against 33 to
34 percent elsewhere (Q06). *Implication:* review how this job type is quoted. *Limit:* 11 jobs.

**F2. Commissioning labour takes more of the cost on two job types (planted).**
Commissioning labour is 21.7 percent of cost for control rooms and 21.5 percent for smart offices, against 18.1 to 18.9
percent for ordinary job types (Q06; +4.2 and +4.0 points against all jobs). Their margin falls further below quote
(-4.6 and -3.1 points) than the ordinary types (-0.5 to -2.1 points) (Q01). *Implication:* estimate commissioning time more
carefully on these two types. *Limit:* quotes record one total cost, so the overrun is inferred from the cost mix, not
measured against a quoted figure per category; 13 jobs per type.

**F3. Sector margin differences probably reflect job mix (to verify).**
Margins by sector range from 16.6 percent (corporate) to 39.2 percent (government), with quoted margins all near 35 to 39
percent (Q02). The loss-making job type in F1 is a large part of the work for some sectors, so the sector figures may only
reflect which job types each sector buys. *Do not present sector differences as sector behaviour until the check in
`findings_validation.sql` (F3) has been run*: it recalculates sector margins without that job type and shows how many of
each sector's jobs it accounts for.

**F4. Most unpaid money is not yet due; overdue money sits mostly in rentals (emergent).**
Calculated from Q03: unpaid balance about KES 71.9m including VAT. About 65.6 percent (47.2m) is not yet due and 34.4
percent (24.7m) is overdue. Rentals hold 18.0m of the 24.7m overdue (73 percent). Only 0.94m (1.3 percent of the unpaid
balance) is more than 90 days overdue. *Implication:* collection effort should focus on rental invoices one to 60 days
overdue.

**F5. A handful of customers pay about 90 days after the due date (planted and emergent).**
The six slowest payers pay between 87.5 and 98.9 days after the due date (Q04), against a typical figure of 10 to 15 days
across the whole customer base (Q05). Three of the six are corporate customers. The slowest, Acacia Public Works Agency,
has the sector "Unknown": its sector was missing in the source data, so a sector view would never have shown it. The
check in `findings_validation.sql` (F5) compares this list with the planted habitual late payers. *Implication:* credit
control on these accounts, and complete the missing master data.

**F6. No trend in payment speed (artefact and open question).**
From 2024 Q1 the weighted days after due vary between 9.5 and 16.1 with no upward or downward trend (Q05). The first
quarter (-6.7 days) is an artefact of the data window: only invoices raised in that quarter can be paid in it, so it holds
only early payments. The second quarter is the slowest in each of the three years (15.9, 16.1 and 14.6 days against 9.5
to 11.4 in the other quarters). No payment seasonality was built into the data, so this is unexplained. It should not be
described as seasonality without further investigation.

## Page 2: rental assets

**F7. Eight assets are on hire under 10 percent of the time and cost far more to repair than they earn (planted).**
Q08: eight assets, on hire 1.4 to 7.6 percent of the time, with repair and service cost between 206 and 783 percent of
their revenue. Calculated: together they earned 2.09m and cost 11.05m to repair and service, which is 11.8 percent of all
repair and service cost and 0.24 percent of rental revenue. The five longest idle gaps (178 to 469 days) all belong to
assets in this group (Q11). *Implication:* retire or redeploy them. *Limit:* repairs are set against revenue only;
purchase cost and depreciation are not included.

**F8. Revenue depends on the daily rate as much as on utilisation (emergent).**
Time on hire: video and streaming 67.0 percent, projection and screens 61.6, conference audio 57.6, LED displays 43.1,
sound reinforcement 40.1, stage lighting 34.9 (Q07). LED displays earn 227.4m at 43.1 percent on hire, more than
projection and screens (166.6m at 61.6 percent), because their daily rates are higher. Conference audio earns only 41.9m.
Rental revenue totals 882.9m; time out of service is 3.5 to 4.1 percent in every category. *Implication:* judge purchases
by revenue per asset-day, not by utilisation alone.

**F9. Event kit carries the heaviest repair burden, partly because of the idle assets (to verify).**
Repair and service cost as a share of revenue: sound reinforcement 16.1 percent, stage lighting 15.9, conference audio
11.1, projection and screens 9.7, LED displays 9.5, video and streaming 8.0 (Q10). The idle assets of F7 sit in five of the
six categories. Calculated without them, sound reinforcement falls to about 12.1 percent and stage lighting to about 14.1,
and conference audio to about 7.2. The check in `findings_validation.sql` (F9) gives the exact figures.

**F10. Double-booking is rare and minor (planted).**
Q09 finds 15 overlaps on 14 assets (one asset twice). Every overlap is one day, inside an existing booking. All second
bookings carry the 15 highest booking numbers, which is a result of how the data was generated and should not be presented
as a pattern. *Implication:* an overlap check at booking entry would prevent them.

## Page 3: commercial and stock

**F11. Win rates differ by division; size effects are noise or artefacts (artefact).**
Win rates are about 44 percent for projects, 64 percent for products and 72 percent for rentals. Within divisions, the
apparent size effects should not be used. For projects, 38.1, 46.4 and 47.4 percent on 84 to 97 quotes per band differ by
less than the sampling noise of about 5 points per band (calculated). For rentals, quotes of 500k to 2m win only 37.6
percent against 72 to 76 percent for smaller ones (Q12), but lost rental quotes were priced from randomly chosen assets
while won quotes are real bookings, so the sizes are not comparable. The check in `findings_validation.sql` (F11) shows
the average prices by outcome.

**F12. Quotes that take over 45 days to decide win less often (planted for projects).**
Pooled across divisions, the win rate is 74.2, 77.9 and 74.9 percent for decisions within 30 days, 72.0 percent for 31
to 45 days and 62.8 percent for more than 45 days (164 quotes) (Q13). The effect was planted only in projects, and the
pooled figure mixes divisions, so the split by division in `findings_validation.sql` (F12) is needed to isolate it.
*Implication:* faster quote turnaround may raise win rates. This is an association, not proof of cause.

**F13. The slowest-moving products tie up stock (planted and emergent).**
Of the eight slowest products (Q14), two never sold: one holds 29 units worth 1.38m at cost, the other holds no stock. The
other six last sold 555 to 864 days ago and hold stock worth about 3.2m at cost (calculated). The planted dead-stock
products all appear in the list with a year or more without a sale (check 15 of the Stage 19 script), together with
products that are slow without having been planted. *Implication:* stop reordering and discount. The exact count and
value are in `findings_validation.sql` (F13).

**F14. Billing is spread across customers (emergent).**
The largest customer is 4.8 percent of billing and the top eight together 27.5 percent. 43 of the 147 customers make 80
percent of billing (Q15). No single customer dominates.

**F15. Large customers buy from all three divisions; most rental customers have never had a project (emergent).**
48 of 147 customers were billed in all three divisions, including each of the eight largest, whose total billing is 43 to
77m (Q17). 91 of 147 customers (62 percent) rent equipment but have never been billed for a project (Q18); the largest is
Horizon Events Ltd with 27.5m of rentals over 201 invoices. *Implication:* a cross-selling opportunity. One of the larger
rental-only customers, Savanna Public Works Agency (13.0m), is also among the six slowest payers (F5), so cross-selling
should consider payment behaviour. *Limit:* revenue only; rental costs are not recorded per booking.

**F16. Quote decision times (artefact).**
Median 6 to 8 days, 90th percentile 38 to 45 days, longest about 60 days (Q16). These follow the distribution chosen for
the data and are not an insight.

## What the analysis cannot tell
- Whether any pattern exists in a real company. The data is synthetic.
- Cause. Associations (F12) are not proof of cause.
- Margin for rentals. Costs are recorded for projects and products, but not per rental booking.
- Anything for periods outside 2023-10-01 to 2026-09-30.

## Verification status
Checks passed in the Stage 19 script (20 of 20) confirm that each view agrees with an independent count or total and
that the planted idle assets, double-bookings and dead-stock products appear in the answers. The explanations marked *to
verify* wait for the results of `findings_validation.sql`.
