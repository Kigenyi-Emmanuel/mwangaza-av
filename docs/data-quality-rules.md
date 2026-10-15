# Data-quality rules

These rules decide what the cleaning step (staging) does to the raw data. Every fix is logged in
`staging.dq_issue` (before and after values) and every rejected row in `staging.rejected_row`.

**Principles**

- **Fix** only when there is a clear, written rule and the original value is kept in the log.
- **Reject** a row only when it cannot be trusted or cannot be linked. Rejected rows are kept, never deleted.
- **Flag** things that are real but odd. They stay in the data and are marked.
- **Keep** business patterns. Cleaning must not remove what the analysis is supposed to find.

| Rule | Applies to | What happens | Action |
|---|---|---|---|
| DQ01 | all | Trim extra spaces, and write status and type words in one standard form (for example all lower case) | fix |
| DQ02 | all | Convert text to dates and numbers. A row that cannot be converted, or that breaks a basic rule of the clean tables (for example a decision date before the quote date), is rejected | reject |
| DQ03 | customer | Customers whose names match once capitals, extra spaces and a leading 'The' are ignored are the same customer. The lowest customer code is kept as the real one | fix |
| DQ04 | customer | A blank or missing sector becomes 'Unknown' and is logged | fix |
| DQ05 | quote, job, sales_order, rental_booking, invoice, payment | Customer codes of duplicate customers are replaced by the real customer code. The original code is kept in its own column | fix |
| DQ06 | invoice | An invoice that repeats another (same job, order or booking, same date, same amount) is rejected. The lowest invoice number is kept | reject |
| DQ07 | invoice | A due date before the invoice date is replaced by the invoice date plus the customer's payment terms. The old value is logged | fix |
| DQ08 | payment_allocation | An allocation larger than its payment is reduced to the payment amount when the payment has only one allocation. The old value is logged | fix |
| DQ09 | all tables that point to another | A row that points to something that does not exist (customer, job, order, booking, asset, product, invoice, payment) is rejected | reject |
| DQ10 | payment_allocation | After the fixes, the total allocated to an invoice must not be more than the invoice total (amount plus VAT). Breaches are flagged | flag |
| DQ11 | rental_booking_line | Two bookings of the same asset on overlapping dates are flagged, not removed. Double-booking is a real event the analysis should find | flag |
| DQ12 | stock_movement | Any time a product's running stock falls below zero is flagged | flag |
| DQ13 | all | Kept exactly as they are: the business patterns planted in the data (cost overruns, a loss-making job type, late payers, idle assets, dead stock, slow quotes). They are findings for the analysis, not errors | keep |

**Which planted problem each rule handles (the answer key lives in `generator.planted_error`)**

| Planted problem | Rule |
|---|---|
| X01 duplicate invoices | DQ06 |
| X02 duplicate customers | DQ03, DQ05 |
| X03 allocations larger than the payment | DQ08 (then DQ10 checks the result) |
| X04 due date before invoice date | DQ07 |
| X05 blank customer sector | DQ04 |
| X09 double-booked assets | DQ11 (flagged, kept) |
| X06, X07, X08, X10, X11, X12 | DQ13 (kept: these are for the analysis to find) |
