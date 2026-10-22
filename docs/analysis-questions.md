# Business questions (analysis schema)

Each question is answered by a view in the `analysis` schema (`sql/10_analysis/run_stage_19.sql`). Every view reads the
reporting layer (`mart`), except Q09 and Q11, which need booking numbers and dates and read `core`. The headline
results of all views can be produced in one table with `sql/10_analysis/headline_summary.sql`.

| ID | Page | Question | Decision it informs | Technique | Pitfall avoided |
|---|---|---|---|---|---|
| Q01 | 1 Profitability and cash | Which job types drift furthest from their quoted margin? | Which job types to re-price | Grouped aggregation on finished jobs; weighted and simple averages | An average of percentages is not the margin of the group |
| Q02 | 1 | Which customer sectors drift furthest from their quoted margin? | Where discounting or overruns hurt most | As Q01, by sector | As Q01 |
| Q03 | 1 | How old is the unpaid balance, by division? | Where to chase payment first | Window over grouped totals (share of the whole) | Ordering buckets by meaning, not alphabetically |
| Q04 | 1 | Which customers pay latest after the due date? | Credit terms and collection effort | Amount-weighted average; minimum evidence threshold | A customer with two payments is not a pattern |
| Q05 | 1 | Is payment behaviour getting better or worse over time? | Whether collection is improving | `LAG` across quarters | Comparing only the first and last period |
| Q06 | 1 | Where does the money go on each job type? | Which cost category to estimate more carefully | Shares of cost; window gives the all-jobs benchmark | Comparing absolute amounts of jobs of different size |
| Q07 | 2 Rental assets | How much of the time is each asset category on hire? | Which kit to buy or retire | Daily asset fact; utilisation as on-hire days over days of life | Dividing by calendar days instead of days in the asset's life |
| Q08 | 2 | Which assets are on hire under 10 percent of the time, and what do they cost to repair? | Retire or redeploy idle kit | Revenue and repairs summed in separate steps, then joined | Joining two fact tables directly multiplies rows |
| Q09 | 2 | Which assets are booked twice on overlapping dates? | Booking process control | Self-join comparing date ranges (`core`) | Counting a pair twice (the join uses `>` on the line id) |
| Q10 | 2 | What do repairs and services cost against rental revenue, by category? | Pricing and maintenance budgets | Two grouped steps joined by category | As Q08 |
| Q11 | 2 | Which assets have the longest idle stretches between bookings? | Redeployment | `LEAD` over each asset's bookings (`core`) | Treating the last booking as having a gap |
| Q12 | 3 Commercial and stock | How does the win rate change with quote size, by division? | Where to spend sales effort | Conditional aggregation with `FILTER` | Counting open quotes as lost |
| Q13 | 3 | Do quotes that take longer to decide win less often? | Quote turnaround targets | Banding with `CASE` | Showing a rate without the number of quotes behind it |
| Q14 | 3 | Which products have not sold for the longest time, and how much stock is tied up? | What to stop buying or discount | Left joins so products that never sold still appear; `NULLS FIRST` | An inner join would hide the products that never sold |
| Q15 | 3 | How concentrated is billing among customers? | Dependence on a few customers | Running share with a window | Ranking ties (a second sort key makes the order stable) |
| Q16 | 3 | How long do quotes take to be decided, by division? | Sales cycle expectations | `percentile_cont` | A mean hides a long tail |
| Q17 | Across divisions | What is each customer worth across the three divisions? | Account management | `FILTER` pivot on one fact table | Joining facts together; revenue only because rental costs are not recorded |
| Q18 | Across divisions | Which customers rent equipment but have never been billed for a project? | Cross-selling | `NOT EXISTS` anti-join | `NOT IN` returns nothing if any value is empty |

## How each answer is checked
Every view is checked in the Stage 19 script against an independent count or total (for example, finished jobs in Q01
and Q02 equal finished jobs in `core`; Q18 equals a second calculation from Q17) and, where a pattern was planted in the
data, against the answer key (for example, the planted idle assets must appear in Q08).
