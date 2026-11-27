# Lab 6 — Reconciliation and time zones

**Goal:** compare the platform’s view with the telco’s settlement file, and
handle the UTC / UTC+3 mismatch correctly.

**Time:** 20 minutes.

## Setup

```bash
make auto STATE=off
make telco MODE=normal
```

## Part A — the settlement file

```bash
make settlements
```

This downloads `telco_settlements_eat.csv` from the telco. Inspect it:

```bash
column -s, -t < telco_settlements_eat.csv | head -20
```

Notice the timestamp column is `settled_at_eat`. It is UTC+3.

Compare it with our table:

```sql
SELECT provider_tx_id, external_ref, channel, gross_amount, fee_amount,
       net_amount, provider_status, settled_at_eat
FROM provider_settlements
ORDER BY id DESC;
```

The CSV is generated from the same table, so the rows match. In a real system
the CSV would arrive from the provider and could disagree.

## Part B — find the seed mismatch

```sql
SELECT
    t.transaction_id,
    t.status AS our_status,
    t.amount AS our_amount,
    s.provider_status,
    s.gross_amount AS telco_amount,
    s.settled_at_eat
FROM transactions t
JOIN provider_settlements s ON s.external_ref = t.transaction_id
WHERE t.status <> LOWER(s.provider_status)
   OR t.amount <> s.gross_amount
ORDER BY t.id;
```

Expected on a fresh seed: `trx_seed_005` is `pending` here but `SUCCESS` at the
telco.

Now find settlements with no matching transaction:

```sql
SELECT s.*
FROM provider_settlements s
LEFT JOIN transactions t ON t.transaction_id = s.external_ref
WHERE t.transaction_id IS NULL;
```

Expected: no rows on a fresh seed.

## Part C — the date shift

`trx_seed_009` was created at `2026-11-24 22:30:00` UTC. The telco settled it at
`2026-11-25 01:30:05` EAT. That is the same instant, but different calendar
days.

```sql
SELECT
    transaction_id,
    created_at AS utc_ts,
    DATE_ADD(created_at, INTERVAL 3 HOUR) AS eat_ts,
    DATE(created_at) AS utc_date,
    DATE(DATE_ADD(created_at, INTERVAL 3 HOUR)) AS eat_date
FROM transactions
WHERE transaction_id = 'trx_seed_009';
```

Find every row where the UTC and EAT dates differ:

```sql
SELECT transaction_id, created_at,
       DATE_ADD(created_at, INTERVAL 3 HOUR) AS eat_ts
FROM transactions
WHERE DATE(created_at) <> DATE(DATE_ADD(created_at, INTERVAL 3 HOUR))
ORDER BY id;
```

## Part D — build a daily report that is correct

A report grouped by `DATE(created_at)` is a UTC report. A report grouped by
`DATE(settled_at_eat)` is an EAT report. Pick one and label it.

UTC report:

```sql
SELECT DATE(created_at) AS day_utc,
       COUNT(*) AS transactions,
       SUM(amount) AS gross
FROM transactions
WHERE status = 'success'
GROUP BY day_utc
ORDER BY day_utc DESC;
```

EAT report:

```sql
SELECT DATE(DATE_ADD(created_at, INTERVAL 3 HOUR)) AS day_eat,
       COUNT(*) AS transactions,
       SUM(amount) AS gross
FROM transactions
WHERE status = 'success'
GROUP BY day_eat
ORDER BY day_eat DESC;
```

They can disagree at the edges of the day. That is expected; the bug is
comparing one with the other without converting.

## Part E — merchant-level reconciliation

```sql
SELECT
    m.name AS merchant,
    t.currency,
    COUNT(*) AS transactions,
    SUM(t.amount) AS gross,
    SUM(COALESCE(t.provider_fee, 0)) AS fees,
    SUM(t.amount - COALESCE(t.provider_fee, 0)) AS net
FROM transactions t
JOIN merchants m ON m.id = t.merchant_id
WHERE t.status = 'success'
GROUP BY m.id, m.name, t.currency
ORDER BY merchant;
```

Compare the `net` column with the settlement rows:

```sql
SELECT s.channel,
       COUNT(*) AS settlements,
       SUM(s.gross_amount) AS gross,
       SUM(s.fee_amount) AS fees,
       SUM(s.net_amount) AS net
FROM provider_settlements s
GROUP BY s.channel;
```

If the totals differ, the difference is your reconciliation break. Explain it
with a query, not a guess.

## Questions

1. Why is it wrong to compare `created_at` with `settled_at_eat` directly?
2. Which timestamp should the customer see on a receipt?
3. Which timestamp should the finance team use for the daily close?
4. A settlement exists but the transaction is pending. Who do you fix first:
   the database or the telco?
5. What would you add to the schema to make reconciliation easier?

## Cleanup

No switches were changed. Remove the CSV if you like:

```bash
rm -f telco_settlements_eat.csv
```
