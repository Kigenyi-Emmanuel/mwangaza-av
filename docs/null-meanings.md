# What an empty cell (NULL) means in the core tables

A NULL is not one thing. In this project it means one of three things, and never "someone forgot".

| Meaning | Where it appears | Example |
|---|---|---|
| **Not applicable** | `invoice.job_id`, `invoice.sales_order_id`, `invoice.rental_booking_id` (exactly one is filled); `job.quote_id`, `sales_order.quote_id`, `rental_booking.quote_id` (empty when there was no quote); `job_cost_line.product_id`; `stock_movement.sales_order_line_id` and `.job_id`; `maintenance_event.rental_booking_id` | A rentals invoice has no job, so its `job_id` is empty |
| **Not yet** | `quote.decision_date` (open or expired quotes); `job.end_date` (jobs in progress) | An open quote has no decision date yet |
| **Only for some kinds of row** | `asset.retired_date` (retired assets only) | An active asset has no retired date |

**Missing data is handled differently.** When a customer's sector was missing, we did not leave it empty. We set it
to `Unknown` and logged the change (rule DQ04), so missing information is visible and countable.

**Rules that guard the empty cells (enforced by the database):** an invoice has exactly one source and it matches the
division; a quote has a decision date exactly when it is won or lost; a completed job has an end date; an asset has a
retired date exactly when it is retired; a stock movement points to the right link for its type.

**Check:** `sql/08_audit/01_null_audit.sql` counts the NULLs in every such column and compares the count with the design.

**Why the invoice table has three optional source columns (decision D4):** one invoice table lets us see the cash of
the whole company in one place, and the three real foreign keys keep every link honest. The price is empty cells and
more careful joins. The alternatives were three separate invoice tables (no empty cells, but company-wide cash needs a
union of three tables) or a single `source_id` column with no foreign key (simple, but the database could not check
that the link is real). In the star schema we will hide this by giving the invoice fact one combined source column.
