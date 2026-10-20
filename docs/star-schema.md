# Reporting layer: star schema (`mart` schema)

The `mart` layer is built from the `core` tables only. It is the layer the SQL analysis and the Power BI pages read from.
The hidden answer key used to test the cleaning is not read when the mart is built.

## Conventions
- **Keys.** Dimension keys reuse the core ids, so any mart row can be traced back to its core row. `dim_date` uses `yyyymmdd`.
- **Not applicable.** Fact tables hold no empty keys. "Not applicable" is a real dimension member with key `0`
  (`dim_date`: no date, for example a quote that is not decided yet; `dim_job`: the invoice is not for a projects job).
- **Combined source.** `fact_invoice.source_number` holds the job, order or booking number, whichever applies,
  so reports do not have to deal with the three optional links in core.
- **One pass per parent.** Sums over child rows (amount paid, job cost, job billing) are calculated once per parent
  row before joining, so nothing is counted twice. The checks compare mart totals with core totals to confirm it.
- **Report information.** `mart.report_info` holds the as-of date (2026-09-30), the start of history and the currency.
- **Amounts** are in KES before VAT unless the column name says otherwise.

## Dimensions
| Table | One row is | Notes |
|---|---|---|
| `dim_date` | one calendar day, 2019-01-01 to 2026-12-31, plus key 0 | year, quarter, month, week, weekday |
| `dim_customer` | one real customer | sector, payment terms, customer since |
| `dim_office` | one office | |
| `dim_division` | one division: projects, products, rentals | |
| `dim_product` | one product | category, supplier, list price, standard cost |
| `dim_asset` | one rental asset | category, purchase cost, daily rate, status |
| `dim_job` | one projects job, plus key 0 | job type, status, dates |
| `dim_cost_category` | one cost category | flag for labour categories |

## Facts
| Table | One row is | Main measures | Dashboard page |
|---|---|---|---|
| `fact_invoice` | one invoice | amounts, paid, outstanding, days past due at the as-of date, ageing bucket | 1 Profitability and cash |
| `fact_payment_allocation` | one payment applied to one invoice | allocated amount, days from invoice, days after due | 1 |
| `fact_job_margin` | one projects job | quoted and actual cost, billing, gross margin, margin variance, cost by category | 1 |
| `fact_job_cost_line` | one cost line on a job | quantity, unit cost, cost amount | 1 |
| `fact_asset_day` | one asset on one day of its life | bookings, on hire, revenue, out of service | 2 Rental assets |
| `fact_maintenance` | one repair or service | cost, days out of service | 2 |
| `fact_quote` | one quote | status, won, closed, days to decide, quoted price and cost | 3 Commercial and stock |
| `fact_sales_line` | one product line on an order | quantity, revenue, cost, gross margin | 3 |
| `fact_stock_movement` | one stock movement | quantity change, value, balance after the movement | 3 |

## Notes for analysis
- Job margin must use finished jobs only (`is_finished`). Jobs still in progress carry only the costs and billing so far.
- A win rate counts won quotes over closed quotes (won, lost or expired). Open quotes are not closed.
- Time utilisation of an asset is on-hire days over days in its life inside the window. Out-of-service days are
  flagged separately so either definition can be used.
