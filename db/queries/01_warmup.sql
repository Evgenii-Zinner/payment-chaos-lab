-- Warm-up queries for the payment lab.
-- Run with:  make sql
-- Or:        make q Q='SELECT COUNT(*) FROM transactions'
-- Or paste into Adminer: http://localhost:8081

-- 1. What tables exist?
SHOW TABLES;

-- 2. What columns does each table have?
DESCRIBE merchants;
DESCRIBE transactions;
DESCRIBE callbacks_log;
DESCRIBE provider_settlements;

-- 3. How much data is there?
SELECT 'merchants' AS table_name, COUNT(*) AS rows_count FROM merchants
UNION ALL SELECT 'transactions', COUNT(*) FROM transactions
UNION ALL SELECT 'callbacks_log', COUNT(*) FROM callbacks_log
UNION ALL SELECT 'provider_settlements', COUNT(*) FROM provider_settlements;

-- 4. The 10 newest transactions.
SELECT transaction_id, merchant_id, order_id, channel, amount, currency, status, created_at
FROM transactions
ORDER BY id DESC
LIMIT 10;

-- 5. How many transactions per status?
SELECT status, COUNT(*) AS count
FROM transactions
GROUP BY status
ORDER BY count DESC;

-- 6. Volume and value per merchant.
SELECT m.id, m.name, COUNT(*) AS transactions, SUM(t.amount) AS gross
FROM transactions t
JOIN merchants m ON m.id = t.merchant_id
GROUP BY m.id, m.name
ORDER BY gross DESC;

-- 7. Volume and value per channel.
SELECT channel, COUNT(*) AS transactions, SUM(amount) AS gross, AVG(amount) AS average_amount
FROM transactions
GROUP BY channel
ORDER BY gross DESC;

-- 8. Webhook attempts, newest first.
SELECT transaction_id, attempt, http_code, response_body, sent_at
FROM callbacks_log
ORDER BY id DESC
LIMIT 20;

-- 9. Telco settlements, newest first.
SELECT provider_tx_id, external_ref, channel, gross_amount, fee_amount, net_amount, provider_status, settled_at_eat
FROM provider_settlements
ORDER BY id DESC;

-- 10. One transaction with its callbacks and settlement side by side.
SELECT
    t.transaction_id,
    t.status AS our_status,
    t.provider_fee,
    c.attempt,
    c.http_code,
    s.provider_status,
    s.gross_amount,
    s.fee_amount,
    s.settled_at_eat
FROM transactions t
LEFT JOIN callbacks_log c ON c.transaction_id = t.transaction_id
LEFT JOIN provider_settlements s ON s.external_ref = t.transaction_id
WHERE t.transaction_id = 'trx_seed_003';
