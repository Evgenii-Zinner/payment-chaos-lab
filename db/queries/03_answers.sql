-- Answers to 02_investigations.sql.
--
-- Expected results below assume the untouched seed from `make reset`, with no
-- `make smoke` payment and auto-traffic off (`make auto STATE=off`). Any extra
-- payment changes counts and percentages, but the shape of the answer is the
-- same.

-- Q1. Successful transactions with no callback row.
SELECT t.transaction_id, t.order_id, t.status
FROM transactions t
LEFT JOIN callbacks_log c ON c.transaction_id = t.transaction_id
WHERE c.id IS NULL
  AND t.status = 'success'
ORDER BY t.id;
-- Expected: trx_seed_004, trx_seed_007.

-- Q2. Pending here, settled at the telco.
SELECT t.transaction_id, t.status AS our_status, s.provider_status, s.net_amount, s.settled_at_eat
FROM transactions t
JOIN provider_settlements s ON s.external_ref = t.transaction_id
WHERE t.status = 'pending'
  AND s.provider_status = 'SUCCESS';
-- Expected: trx_seed_005.

-- Q3. Duplicate order_id values.
SELECT order_id, COUNT(*) AS occurrences,
       GROUP_CONCAT(status ORDER BY id) AS statuses,
       GROUP_CONCAT(transaction_id ORDER BY id) AS transactions
FROM transactions
GROUP BY order_id
HAVING COUNT(*) > 1
ORDER BY occurrences DESC;
-- Expected: ord_dup_1 -> 2 -> success,failed.

-- Q4. Every attempt for transactions that were retried.
SELECT c.transaction_id, c.attempt, c.http_code, c.response_body, c.sent_at
FROM callbacks_log c
JOIN (
    SELECT transaction_id
    FROM callbacks_log
    GROUP BY transaction_id
    HAVING COUNT(*) > 1
) retried ON retried.transaction_id = c.transaction_id
ORDER BY c.transaction_id, c.attempt;
-- Expected: trx_seed_003 attempts 1 (500) and 2 (200).

-- Q5. Successful transactions with a missing fee.
SELECT transaction_id, channel, amount, status
FROM transactions
WHERE status = 'success'
  AND provider_fee IS NULL
ORDER BY id;
-- Expected: trx_seed_002, trx_seed_004.

-- Q6. Amount/status disagreements between our DB and the settlement file.
SELECT
    t.transaction_id,
    t.status AS our_status,
    t.amount AS our_amount,
    s.provider_status,
    s.gross_amount AS telco_amount,
    CASE
        WHEN t.amount <> s.gross_amount THEN 'amount mismatch'
        WHEN t.status <> LOWER(s.provider_status) THEN 'status mismatch'
        ELSE 'ok'
    END AS result
FROM transactions t
JOIN provider_settlements s ON s.external_ref = t.transaction_id
WHERE t.amount <> s.gross_amount
   OR t.status <> LOWER(s.provider_status)
ORDER BY t.id;
-- Expected: trx_seed_005 -> pending vs success -> status mismatch.

-- Q7. Settlements with no matching transaction.
SELECT s.provider_tx_id, s.external_ref, s.gross_amount, s.provider_status
FROM provider_settlements s
LEFT JOIN transactions t ON t.transaction_id = s.external_ref
WHERE t.transaction_id IS NULL;
-- Expected: no rows on a fresh seed.

-- Q8. Callback failure rate by HTTP code.
SELECT http_code,
       COUNT(*) AS attempts,
       ROUND(100 * COUNT(*) / (SELECT COUNT(*) FROM callbacks_log), 1) AS pct
FROM callbacks_log
GROUP BY http_code
ORDER BY http_code;
-- Expected: 200 -> 3 (60.0%), 403 -> 1 (20.0%), 500 -> 1 (20.0%).

-- Q9. UTC vs East Africa Time (UTC+3).
SELECT
    transaction_id,
    created_at AS utc_ts,
    DATE_ADD(created_at, INTERVAL 3 HOUR) AS eat_ts,
    DATE(DATE_ADD(created_at, INTERVAL 3 HOUR)) AS eat_date
FROM transactions
WHERE DATE(created_at) <> DATE(DATE_ADD(created_at, INTERVAL 3 HOUR))
ORDER BY id;
-- Expected on a fresh seed: trx_seed_009 (2026-11-24 22:30 UTC -> 2026-11-25 01:30 EAT).
-- Rows created near midnight can also move to the next day.

-- Q10. Pending for more than 10 minutes.
SELECT transaction_id, order_id, channel, amount, created_at,
       TIMESTAMPDIFF(MINUTE, created_at, UTC_TIMESTAMP()) AS minutes_pending
FROM transactions
WHERE status = 'pending'
  AND created_at < UTC_TIMESTAMP() - INTERVAL 10 MINUTE
ORDER BY created_at;
-- Expected on a fresh seed: trx_seed_005.

-- Q11. Highest fee percentage.
SELECT transaction_id, channel, amount, provider_fee,
       ROUND(provider_fee / amount * 100, 2) AS fee_pct
FROM transactions
WHERE provider_fee IS NOT NULL
  AND amount > 0
ORDER BY fee_pct DESC;
-- Expected: the 1.75% rows (seed_001, seed_003, seed_007, seed_009).

-- Q12. Daily merchant report for successful transactions.
SELECT
    DATE(t.created_at) AS day,
    m.name AS merchant,
    COUNT(*) AS transactions,
    SUM(t.amount) AS gross,
    SUM(COALESCE(t.provider_fee, 0)) AS fees,
    SUM(t.amount - COALESCE(t.provider_fee, 0)) AS net
FROM transactions t
JOIN merchants m ON m.id = t.merchant_id
WHERE t.status = 'success'
GROUP BY day, m.id, m.name
ORDER BY day DESC, gross DESC;

-- Q13. Provider fee vs merchant commission.
SELECT
    t.transaction_id,
    t.channel,
    t.amount,
    t.provider_fee,
    ROUND(t.amount * m.commission_pct / 100, 2) AS expected_commission,
    ROUND(t.provider_fee - (t.amount * m.commission_pct / 100), 2) AS difference
FROM transactions t
JOIN merchants m ON m.id = t.merchant_id
WHERE t.provider_fee IS NOT NULL
ORDER BY ABS(difference) DESC;
-- Expected: trx_seed_009 is off by -25.00 because merchant 77 charges 2.00%
-- but the telco fee was 1.75%.

-- Q14. Callbacks that failed at least once, and whether they recovered.
SELECT transaction_id,
       COUNT(*) AS attempts,
       SUM(http_code >= 400 OR http_code IS NULL) AS failures,
       MAX(http_code = 200) AS eventually_ok
FROM callbacks_log
GROUP BY transaction_id
HAVING failures > 0
ORDER BY transaction_id;
-- Expected: trx_seed_002 -> 403, never ok; trx_seed_003 -> 500 then 200, ok.

-- Q15. Callback success rate by channel.
SELECT
    t.channel,
    COUNT(c.id) AS attempts,
    SUM(c.http_code = 200) AS ok,
    ROUND(100 * SUM(c.http_code = 200) / COUNT(c.id), 1) AS ok_pct
FROM transactions t
JOIN callbacks_log c ON c.transaction_id = t.transaction_id
GROUP BY t.channel
ORDER BY ok_pct ASC;
-- Expected: MTN_ZM 50.0%, AIRTEL_ZM 50.0%, MPESA_KE 100.0%.
