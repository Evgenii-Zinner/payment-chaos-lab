# Lab 7 — Load, duplicates, and idempotency

**Goal:** see what happens under bursty traffic and how the idempotency lock
behaves.

**Time:** 20 minutes.

## Setup

```bash
make auto STATE=off
make telco MODE=normal
make merchant MODE=ok
```

## Part A — burst

Send 20 payments:

```bash
make fire N=20
```

The response includes every HTTP code. Most should be 200.

Check the volume:

```sql
SELECT COUNT(*) AS transactions,
       MIN(created_at) AS first_seen,
       MAX(created_at) AS last_seen
FROM transactions
WHERE order_id LIKE 'ord_%';
```

Watch the log grow:

```bash
wc -l logs/aggregator/app.log
make fire N=20
wc -l logs/aggregator/app.log
```

## Part B — duplicate order inside the lock window

Send the same `order_id` three times:

```bash
make fire N=3 DUP=1
```

Expected: the first request is accepted; the next two get **409** and the
aggregator logs `duplicate_retry_storm`.

```bash
jq -c 'select(.msg == "duplicate_retry_storm")' logs/aggregator/app.log | tail -3
```

The lock is in Redis:

```bash
docker compose exec redis redis-cli --scan --pattern 'idem:*'
# Pick one of the keys it prints and inspect the TTL (seconds):
docker compose exec redis redis-cli ttl idem:42:ord_replace_me
```

The key expires after 10 seconds. After it expires, the same order can create a
new transaction. Try it:

```bash
ORDER="ord_idem_$(date +%s)"

# first request
curl -i -s -X POST http://localhost:8080/api/v1/payments/collect \
  -H 'Authorization: Bearer tok_zoyk_live_42' \
  -H 'Content-Type: application/json' \
  -d "{\"order_id\":\"$ORDER\",\"amount\":250,\"currency\":\"ZMW\",\"channel\":\"MTN_ZM\",\"phone\":\"260971112233\"}"

# immediately again -> 409
curl -i -s -X POST http://localhost:8080/api/v1/payments/collect \
  -H 'Authorization: Bearer tok_zoyk_live_42' \
  -H 'Content-Type: application/json' \
  -d "{\"order_id\":\"$ORDER\",\"amount\":250,\"currency\":\"ZMW\",\"channel\":\"MTN_ZM\",\"phone\":\"260971112233\"}"

# wait for the lock to expire, then try again -> 200 and a second transaction
sleep 11
curl -i -s -X POST http://localhost:8080/api/v1/payments/collect \
  -H 'Authorization: Bearer tok_zoyk_live_42' \
  -H 'Content-Type: application/json' \
  -d "{\"order_id\":\"$ORDER\",\"amount\":250,\"currency\":\"ZMW\",\"channel\":\"MTN_ZM\",\"phone\":\"260971112233\"}"
```

Now look for duplicates:

```sql
SELECT order_id, COUNT(*) AS rows_count,
       GROUP_CONCAT(transaction_id ORDER BY id) AS transactions,
       GROUP_CONCAT(status ORDER BY id) AS statuses
FROM transactions
WHERE order_id = '<your order_id>'
GROUP BY order_id;
```

## Part C — a race

Fire ten requests with the same `order_id` at the same time:

```bash
seq 1 10 | xargs -P 10 -I{} curl -s -o /dev/null -w '%{http_code}\n' \
  -X POST http://localhost:8080/api/v1/payments/collect \
  -H 'Authorization: Bearer tok_zoyk_live_42' \
  -H 'Content-Type: application/json' \
  -d '{"order_id":"ord_race_1","amount":100,"currency":"ZMW","channel":"MTN_ZM","phone":"260971112233"}' \
  | sort | uniq -c
```

Expected: exactly one 200, the rest 409. Verify:

```sql
SELECT COUNT(*) AS rows_count
FROM transactions
WHERE order_id = 'ord_race_1';
```

Expected: 1.

## Part D — background traffic

```bash
make auto STATE=on
sleep 30
make auto STATE=off
```

Count what arrived:

```sql
SELECT DATE_FORMAT(created_at, '%Y-%m-%d %H:%i') AS minute,
       COUNT(*) AS transactions
FROM transactions
GROUP BY minute
ORDER BY minute DESC
LIMIT 10;
```

## Questions

1. Why is the idempotency key scoped to `merchant_id + order_id`?
2. What happens if the Redis key expires while the first request is still in
   flight?
3. Is a 409 the right response for a duplicate, or should the API return the
   original transaction?
4. Where should idempotency live if Redis is unavailable?
5. What would you alert on: 409 rate, duplicate row count, or both?

## Challenge

Add a unique index on `(merchant_id, order_id)` in a scratch copy of the schema
and see which seed rows fail to insert. Why can’t the production table have that
constraint as-is?

<details>
<summary>Hint</summary>

`ord_dup_1` exists twice on purpose. A unique constraint would reject the
second row unless the design allowed one order to have multiple attempts with a
different key.

</details>

## Cleanup

```bash
make auto STATE=off
```
