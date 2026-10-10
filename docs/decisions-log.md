# Decisions log

Status key: **Accepted** = the project owner confirmed it. **Provisional** = proposed, not yet explicitly reviewed.

| ID | Date | Decision | Alternatives considered | Reason | Status |
|---|---|---|---|---|---|
| D1 | 2026-10-10 | PostgreSQL is the database engine | SQL Server, MySQL | Free to reproduce, strong analytical SQL, common in data engineering | Accepted |
| D2 | 2026-10-10 | Two layers: normalised `core`, star `mart` | Star only; report straight off core | Star-only skips ETL; core-only causes join fan-out and suits Power BI poorly | Accepted |
| D3 | 2026-10-10 | Mart is a constellation of facts sharing dimensions | One big fact | Enables the cross-division customer question | Provisional |
| D4 | 2026-10-10 | One `invoice` table for all divisions | Three invoice tables | Company-wide cash view, simpler payments | Provisional |
| D5 | 2026-10-10 | `quote` covers all three divisions | Projects only | Quote-win analysis across the company | Provisional |
| D6 | 2026-10-10 | No purchase orders; stock tracked by `stock_movement` | Full purchasing model | Keeps scope manageable | Provisional |
| D7 | 2026-10-10 | VAT excluded from all margin figures | Include VAT | Margins are cleaner. Current VAT treatment to be verified before any VAT figure appears | Provisional |
| D8 | 2026-10-10 | Gross margin only | Net profit | Overheads and payroll are out of scope | Provisional |
| D9 | 2026-10-10 | Synthetic data only, fictional names throughout | Real or anonymised company data | No authorised real data; low privacy exposure | Accepted |
| D10 | 2026-10-10 | Data generated in PostgreSQL (SQL only) with a fixed seed. Python is kept for future projects | Python generator | Stays in the agreed stack, reproducible with PostgreSQL alone | Accepted |
| D11 | 2026-10-10 | Single currency (KES) | Multi-currency | Simplicity | Provisional |
| D12 | 2026-10-10 | No history of changes to dimensions | Slowly changing dimensions | Simplicity for synthetic data | Provisional |
| D13 | 2026-10-10 | The database does not stop double-booked assets | Exclusion constraint on asset and dates | We want to be able to ask "which assets are double-booked?", as real systems often allow it | Provisional |
| D14 | 2026-10-10 | Rules across rows or tables are tested, not enforced by triggers | Triggers | Simpler to read and teach; tests record the proof | Provisional |
| D15 | 2026-10-10 | `invoice.customer_id` is stored on the invoice and tested against the source | Look up customer through job, order or booking | Simpler reporting; the duplicate must be tested | Provisional |
| D16 | 2026-10-10 | Small lookup lists (sectors, offices, job types, cost categories, product and asset categories) are loaded straight into `core` | Pass them through raw and staging | They are short controlled lists, not messy source data. Planted errors go into transactional and customer data | Provisional |
| D17 | 2026-10-10 | Labour costs are split into installation labour and programming and commissioning labour | One labour category | Lets us see where estimates go wrong. Both count as direct costs in job margin | Provisional |
| D18 | 2026-10-10 | Add `customer_code` and `supplier_code` to core | Use customer and supplier names as keys | Names can be spelled two ways; codes are how real exports link records. Done while the tables are empty | Provisional |
| D19 | 2026-10-10 | Raw tables: every data column is text, no keys or rules, rows linked by business keys | Typed raw tables with constraints | Dirty data must be able to land. Staging does the typing and cleaning | Provisional |
| D20 | 2026-10-10 | Assumptions register accepted as proposed (bulk accept, not reviewed row by row) | Review each row | Owner chose to move faster. VAT (P11) still needs verifying and seasonality (R06) is unknown. Any row can be changed later | Accepted |
| D21 | 2026-10-10 | The generator keeps an answer key in its own schema (`generator`): copied parameters, hidden customer traits, and a list of every planted error | Keep parameters only in Excel and hide traits in code | Lets us later test whether our checks and analysis found what we planted | Provisional |
| D22 | 2026-10-10 | Product prices and rental rates are drawn inside a band per category (register sheet `Price_bands`). Dead-stock products and idle assets are marked in the answer key and enforced when sales and bookings are generated | One price range for everything | Cables and displays should not cost the same. Marks let us test later that the analysis finds what we planted | Provisional |
