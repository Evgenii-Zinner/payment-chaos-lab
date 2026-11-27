# Lab 3 — SQL basics

**Goal:** learn the schema by querying it, then answer operational questions.

**Time:** 25 minutes.

## Setup

```bash
make auto STATE=off
make sql
```

The database is `payments_lab`. If you are using Adminer, connect to server
`db` with user `root` and password `rootpass`.

## Part A — discover

1. List tables:

   ```sql
   SHOW TABLES;
   ```

2. Describe each table:

   ```sql
   DESCRIBE transactions;
   DESCRIBE callbacks_log;
   DESCRIBE provider_settlements;
   DESCRIBE merchants;
   ```

3. How many rows are in each?

   ```sql
   SELECT 'transactions' AS t, COUNT(*) FROM transactions
   UNION ALL SELECT 'callbacks', COUNT(*) FROM callbacks_log
   UNION ALL SELECT 'settlements', COUNT(*) FROM provider_settlements;
   ```

4. Show the 10 newest transactions:

   ```sql
   SELECT transaction_id, order_id, channel, amount, status, created_at
   FROM transactions
   ORDER BY id DESC
   LIMIT 10;
   ```

## Part B — filter and aggregate

5. How many transactions per status?

   ```sql
   SELECT status, COUNT(*) AS count
   FROM transactions
   GROUP BY status
   ORDER BY count DESC;
   ```

6. What is the total value per channel?

   ```sql
   SELECT channel, COUNT(*) AS count, SUM(amount) AS gross
   FROM transactions
   GROUP BY channel
   ORDER BY gross DESC;
   ```

7. Which merchant has the most transactions?

   ```sql
   SELECT m.id, m.name, COUNT(*) AS count, SUM(t.amount) AS gross
   FROM transactions t
   JOIN merchants m ON m.id = t.merchant_id
   GROUP BY m.id, m.name
   ORDER BY count DESC;
   ```

8. Show all failed transactions and their error codes:

   ```sql
   SELECT transaction_id, order_id, error_code, created_at
   FROM transactions
   WHERE status = 'failed'
   ORDER BY id DESC;
   ```

## Part C — joins

9. For each transaction, show its callbacks:

   ```sql
   SELECT t.transaction_id, t.status, c.attempt, c.http_code, c.sent_at
   FROM transactions t
   LEFT JOIN callbacks_log c ON c.transaction_id = t.transaction_id
   ORDER BY t.id DESC, c.attempt;
   ```

10. Which transactions have no callback row?

    ```sql
    SELECT t.transaction_id, t.status
    FROM transactions t
    LEFT JOIN callbacks_log c ON c.transaction_id = t.transaction_id
    WHERE c.id IS NULL
    ORDER BY t.id;
    ```

11. Which transactions have a settlement?

    ```sql
    SELECT t.transaction_id, t.status AS our_status,
           s.provider_status, s.net_amount
    FROM transactions t
    JOIN provider_settlements s ON s.external_ref = t.transaction_id
    ORDER BY t.id;
    ```

## Part D — the seed puzzles

Run this:

```sql
SELECT transaction_id, order_id, status, provider_fee, error_code, created_at
FROM transactions
WHERE transaction_id LIKE 'trx_seed_%'
ORDER BY id;
```

Answer these without looking at `db/queries/03_answers.sql`:

1. Which successful transaction has no fee?
2. Which successful transaction has no callback?
3. Which pending transaction was actually settled by the telco?
4. Which two rows share an `order_id`?
5. Which transaction’s UTC date differs from its EAT date?

## Challenge

Write a query that returns, for every transaction, these columns:

- `transaction_id`
- `status`
- `attempts` (number of callback rows, 0 if none)
- `last_http_code` (the HTTP code of the highest attempt, NULL if none)
- `settled` (`yes`/`no`)

<details>
<summary>Hint</summary>

Use `LEFT JOIN`, `COUNT`, and a correlated subquery or a window function.

</details>

<details>
<summary>One possible answer</summary>

```sql
SELECT
    t.transaction_id,
    t.status,
    COUNT(c.id) AS attempts,
    (SELECT c2.http_code
     FROM callbacks_log c2
     WHERE c2.transaction_id = t.transaction_id
     ORDER BY c2.attempt DESC
     LIMIT 1) AS last_http_code,
    CASE WHEN s.id IS NULL THEN 'no' ELSE 'yes' END AS settled
FROM transactions t
LEFT JOIN callbacks_log c ON c.transaction_id = t.transaction_id
LEFT JOIN provider_settlements s ON s.external_ref = t.transaction_id
GROUP BY t.id, t.transaction_id, t.status, s.id
ORDER BY t.id;
```

</details>

## Check yourself

- `SELECT *` is fine for exploring, but explicit columns make joins readable.
- `COUNT(*)` counts rows; `COUNT(column)` ignores NULLs.
- `LEFT JOIN` plus `WHERE right.id IS NULL` finds missing rows.
- `SUM` ignores NULL, which is why `COALESCE(provider_fee, 0)` matters.
