-- Investigation exercises. Write the queries yourself before opening
-- 03_answers.sql. Each question has a hint.
--
-- Turn auto-traffic off first so the data stops changing:
--   make auto STATE=off

-- Q1. Which successful transactions never produced a callback?
-- Hint: LEFT JOIN callbacks_log and test for NULL.

-- Q2. Which transactions are still pending in our database but were already
--     settled successfully at the telco?
-- Hint: join provider_settlements on external_ref = transaction_id.

-- Q3. Which order_id values appear more than once? Show the count and the
--     statuses involved.
-- Hint: GROUP BY order_id HAVING COUNT(*) > 1.

-- Q4. Which transactions needed more than one webhook attempt? Show every
--     attempt, not just the count.
-- Hint: a subquery with HAVING COUNT(*) > 1, or join back to callbacks_log.

-- Q5. Which successful transactions have a NULL provider_fee?
-- Hint: WHERE status = 'success' AND provider_fee IS NULL.

-- Q6. Reconcile our transactions against the telco settlement file.
--     Show only rows where the amount or status disagrees.
-- Hint: LEFT JOIN provider_settlements; compare t.amount with s.gross_amount
--       and t.status with LOWER(s.provider_status).

-- Q7. Which settlements do not match any transaction?
-- Hint: LEFT JOIN transactions ON t.transaction_id = s.external_ref
--       WHERE t.transaction_id IS NULL.

-- Q8. What is the webhook failure rate by HTTP status code?
-- Hint: GROUP BY http_code; use SUM(http_code = 200) / COUNT(*) for a rate.

-- Q9. Show every transaction's created_at in UTC and in East Africa Time
--     (UTC+3), plus the date only. Then find transactions that fall on a
--     different calendar day in EAT.
-- Hint: DATE_ADD(created_at, INTERVAL 3 HOUR), DATE().

-- Q10. Which pending transactions are older than 10 minutes?
-- Hint: TIMESTAMPDIFF(MINUTE, created_at, UTC_TIMESTAMP()) > 10.

-- Q11. Which transaction has the highest fee percentage
--      (provider_fee / amount)? Ignore rows with NULL fee.
-- Hint: ORDER BY provider_fee / amount DESC.

-- Q12. Build a daily merchant report: date, merchant, transaction count,
--      gross amount, fees, net amount. Use only successful transactions and
--      treat NULL fees as zero.
-- Hint: DATE(created_at), COALESCE(provider_fee, 0).

-- Q13. Find transactions where the telco fee differs from the merchant
--      commission. Merchant commission is commission_pct percent of amount.
-- Hint: join merchants; compare provider_fee with amount * commission_pct / 100.

-- Q14. How many callbacks eventually succeeded after at least one failure?
-- Hint: group by transaction_id; use MAX(http_code = 200) and
--       MIN(http_code) or SUM(http_code >= 400).

-- Q15. Which channel has the worst callback success rate?
-- Hint: join transactions to callbacks_log, group by channel, and compare
--       successful attempts with all attempts.
