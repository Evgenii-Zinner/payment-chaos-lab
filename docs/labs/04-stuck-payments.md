# Lab 4 — Stuck payments

**Goal:** reproduce the two ways a payment gets stuck in `pending`, prove it with
SQL, and replay the missing callback.

**Time:** 25 minutes.

## Setup

```bash
make auto STATE=off
make telco MODE=normal
make merchant MODE=ok
```

## Scenario A — the telco drops the callback

```bash
make telco MODE=drop_callback
ORDER="ord_stuck_$(date +%s)"
make pay ORDER="$ORDER"
make telco MODE=normal
```

Wait 2 seconds, then query:

```sql
SELECT transaction_id, order_id, status, provider_fee, created_at
FROM transactions
WHERE order_id = '<your order_id>';
```

Expected: `status = 'pending'`, `provider_fee IS NULL`.

Now check the telco side:

```sql
SELECT external_ref, provider_status, gross_amount, fee_amount, net_amount, settled_at_eat
FROM provider_settlements
WHERE external_ref = '<your transaction_id>';
```

Expected: a `SUCCESS` settlement. The telco has the money; our database does
not know.

Check the callback table:

```sql
SELECT * FROM callbacks_log WHERE transaction_id = '<your transaction_id>';
```

Expected: no rows.

Check the telco log:

```bash
jq -c 'select(.msg == "CHAOS_DROPPED_CALLBACK")' logs/telco/telco.log | tail -1
```

### Replay the missing callback by hand

In a real incident you would not usually do this, but it proves the point:

```bash
curl -s -X POST http://localhost:8080/api/v1/webhooks/telco \
  -H 'Content-Type: application/json' \
  -d '{"external_ref":"<your transaction_id>","status":"success","fee":4.38}'
```

The `4.38` matches the 250 ZMW payment sent by `make pay`. If you used a
different amount, take `fee_amount` from the settlement row instead.

Then re-run the transaction query. It should now be `success`, and a merchant
webhook should appear in `callbacks_log`.

## Scenario B — the callback is malformed

```bash
make telco MODE=bad_format
ORDER="ord_bad_$(date +%s)"
make pay ORDER="$ORDER"
make telco MODE=normal
```

Wait 2 seconds.

```sql
SELECT transaction_id, order_id, status
FROM transactions
WHERE order_id = '<your order_id>';

SELECT * FROM provider_settlements
WHERE external_ref = '<your transaction_id>';
```

Expected: transaction `pending`, settlement `SUCCESS`.

Find the parse error:

```bash
jq -c 'select(.msg == "telco_callback_parse_error")' logs/aggregator/app.log | tail -1
```

The `raw` field shows the body the aggregator could not parse.

Replay the correct body:

```bash
curl -s -X POST http://localhost:8080/api/v1/webhooks/telco \
  -H 'Content-Type: application/json' \
  -d '{"external_ref":"<your transaction_id>","status":"success","fee":4.38}'
```

The transaction should recover.

## Detect stuck payments at scale

```sql
-- Pending for more than 10 minutes
SELECT transaction_id, order_id, channel, amount,
       TIMESTAMPDIFF(MINUTE, created_at, UTC_TIMESTAMP()) AS minutes_pending
FROM transactions
WHERE status = 'pending'
  AND created_at < UTC_TIMESTAMP() - INTERVAL 10 MINUTE
ORDER BY created_at;

-- Pending here but settled at the telco
SELECT t.transaction_id, t.order_id, t.status, s.provider_status, s.settled_at_eat
FROM transactions t
JOIN provider_settlements s ON s.external_ref = t.transaction_id
WHERE t.status = 'pending'
  AND s.provider_status = 'SUCCESS';

-- Successful here but no settlement row at the telco
SELECT t.transaction_id, t.order_id, t.status
FROM transactions t
LEFT JOIN provider_settlements s ON s.external_ref = t.transaction_id
WHERE t.status = 'success' AND s.id IS NULL;
```

## Questions

1. Which component should own the reconciliation job?
2. How often should it run?
3. What should it do when it finds a pending transaction with a successful
   settlement: auto-fix, alert, or both?
4. Why is replaying a callback by hand risky in production?
5. What would you alert on: pending count, pending age, or both?

## Cleanup

```bash
make telco MODE=normal
make merchant MODE=ok
```
