# Chaos playbook

Each scenario follows the same shape: set a baseline, trigger the failure, read
the logs, confirm with SQL, then reset the switch. Run the scenarios one at a
time so you can attribute the evidence.

## Before you start

```bash
make up
make smoke
make auto STATE=off        # stop background traffic
make telco MODE=normal
make merchant MODE=ok
```

Useful terminals:

```bash
# terminal 1
make tail

# terminal 2
make sql
```

Or keep Grafana open at http://localhost:3000 → **Explore**.

A useful baseline query:

```sql
SELECT transaction_id, order_id, status, provider_fee, error_code, created_at
FROM transactions
ORDER BY id DESC
LIMIT 5;
```

## Scenario 1 — telco timeout

```bash
make telco MODE=timeout
make fire N=1
```

What happens:

1. The aggregator inserts the transaction as `pending`.
2. It calls the telco and waits 5 seconds.
3. The telco sleeps 6 seconds before finishing.
4. The aggregator times out, marks the transaction `failed` with
   `TELCO_TIMEOUT`, then sleeps 5 seconds to force nginx’s 4-second read
   timeout.
5. The client sees nginx **504**.
6. The telco may still settle and send a callback afterwards. If it does, the
   transaction can flip from `failed` to `success`.

Evidence:

```bash
jq -c 'select(.msg == "upstream_timeout")' logs/aggregator/app.log | tail -1
tail -n 5 logs/nginx/access.log
```

```sql
SELECT transaction_id, status, error_code, provider_fee
FROM transactions
ORDER BY id DESC
LIMIT 1;

SELECT * FROM provider_settlements ORDER BY id DESC LIMIT 1;
SELECT * FROM callbacks_log ORDER BY id DESC LIMIT 5;
```

Debrief:

- Who timed out: the aggregator or nginx?
- Is a timeout a failure if the payment later succeeds?
- What should the merchant do with a 504?

Reset:

```bash
make telco MODE=normal
```

## Scenario 2 — telco 503

```bash
make telco MODE=503
make fire N=1
```

What happens:

1. The telco returns 503 immediately.
2. The aggregator marks the transaction `failed` with `TELCO_503`.
3. The aggregator returns **502** to the caller.
4. No settlement and no callback are created.

Evidence:

```bash
jq -c 'select(.msg == "upstream_5xx")' logs/aggregator/app.log | tail -1
tail -n 3 logs/nginx/access.log
```

```sql
SELECT transaction_id, status, error_code
FROM transactions
ORDER BY id DESC
LIMIT 1;
```

Debrief:

- Why is the client code 502 instead of 503?
- Should this transaction be retried automatically?
- What would a circuit breaker change?

Reset:

```bash
make telco MODE=normal
```

## Scenario 3 — dropped telco callback

This is the classic “money moved but our database does not know” bug.

```bash
make telco MODE=drop_callback
make fire N=1
make telco MODE=normal
```

What happens:

1. The telco accepts the push and inserts a `provider_settlements` row.
2. The telco deliberately does **not** call the aggregator.
3. The transaction stays `pending` forever.
4. The telco log records `CHAOS_DROPPED_CALLBACK`.

Evidence:

```bash
jq -c 'select(.msg == "CHAOS_DROPPED_CALLBACK")' logs/telco/telco.log | tail -1
```

```sql
SELECT t.transaction_id, t.status AS our_status,
       s.provider_status, s.net_amount, s.settled_at_eat
FROM transactions t
JOIN provider_settlements s ON s.external_ref = t.transaction_id
WHERE t.status = 'pending';
```

Debrief:

- Which table is the source of truth for “did the customer pay”?
- What is the reconciliation job’s input and output?
- How long should a payment stay pending before someone is paged?

Reset:

```bash
make telco MODE=normal
```

## Scenario 4 — malformed telco callback

```bash
make telco MODE=bad_format
make fire N=1
make telco MODE=normal
```

What happens:

1. The telco settles and sends a callback with the wrong schema.
2. The aggregator cannot read `external_ref`, logs
   `telco_callback_parse_error`, and returns 400.
3. The transaction stays `pending`.
4. The settlement exists.

Evidence:

```bash
jq -c 'select(.msg == "telco_callback_parse_error")' logs/aggregator/app.log | tail -1
```

```sql
SELECT t.transaction_id, t.status, s.provider_status
FROM transactions t
JOIN provider_settlements s ON s.external_ref = t.transaction_id
WHERE t.status = 'pending';
```

Debrief:

- The telco sent a 200? Check nginx. What did the aggregator return?
- Is retrying the same malformed body useful?
- What should the aggregator do with the raw body for debugging?

Reset:

```bash
make telco MODE=normal
```

## Scenario 5 — merchant WAF block (403)

```bash
make merchant MODE=403_waf
make fire N=1
make merchant MODE=ok
```

What happens:

1. The payment succeeds at the telco and the transaction becomes `success`.
2. The aggregator tries the merchant webhook twice.
3. Both attempts get 403.
4. `callbacks_log` has two rows with `http_code = 403`.

Evidence:

```bash
jq -c 'select(.msg == "webhook_attempt")' logs/aggregator/app.log | tail -2
```

```sql
SELECT transaction_id, attempt, http_code, response_body
FROM callbacks_log
ORDER BY id DESC
LIMIT 4;
```

Debrief:

- Is the payment failed? (No — only the notification failed.)
- What would you tell the merchant?
- Should the aggregator retry forever?

## Scenario 6 — merchant redirect (302)

```bash
make merchant MODE=302_redirect
make fire N=1
make merchant MODE=ok
```

What happens:

1. The merchant returns 302 instead of 200.
2. The aggregator does not follow redirects.
3. `callbacks_log` records `302` twice.

Evidence:

```sql
SELECT transaction_id, attempt, http_code
FROM callbacks_log
ORDER BY id DESC
LIMIT 4;
```

Debrief:

- Why is following redirects dangerous for webhooks?
- What is the difference between “delivered” and “accepted”?

## Scenario 7 — merchant 500

```bash
make merchant MODE=500_crash
make fire N=1
make merchant MODE=ok
```

What happens:

1. The transaction succeeds.
2. Both webhook attempts return 500.
3. After the merchant recovers, use the manual retry:

```bash
make retry TRX=trx_replace_me
```

4. A new attempt is appended to `callbacks_log`, this time 200.

Evidence:

```sql
SELECT transaction_id, attempt, http_code, response_body, sent_at
FROM callbacks_log
WHERE transaction_id = '<transaction_id>'
ORDER BY attempt;
```

Debrief:

- How do you know which transactions need a manual retry?
- What is the risk of retrying a webhook that actually succeeded but returned
  an error?

## Scenario 8 — bad HMAC

```bash
make merchant MODE=bad_hmac
make fire N=1
make merchant MODE=ok
```

What happens:

1. The merchant returns 400 “Invalid HMAC signature”.
2. `callbacks_log` records 400.
3. The payment itself is still successful.

Debrief:

- Which side owns the secret?
- How would you rotate the secret without losing callbacks?
- Why is a 400 different from a 403?

## Scenario 9 — duplicate retry storm

```bash
make fire N=3 DUP=1
```

What happens:

1. The merchant sends three requests with the same `order_id`.
2. The first creates a transaction and takes the Redis lock.
3. The next two get **409** and log `duplicate_retry_storm`.
4. After 10 seconds the lock expires, so a later retry can create another
   transaction.

Evidence:

```bash
jq -c 'select(.msg == "duplicate_retry_storm")' logs/aggregator/app.log | tail -3
```

```sql
SELECT order_id, COUNT(*) AS rows_count,
       GROUP_CONCAT(transaction_id ORDER BY id) AS transactions,
       GROUP_CONCAT(status ORDER BY id) AS statuses
FROM transactions
GROUP BY order_id
HAVING COUNT(*) > 1;
```

Debrief:

- Is a 10-second lock enough for a real retry storm?
- Should idempotency live in Redis or in the database?
- What would you use as the idempotency key in production?

## Scenario 10 — background traffic

```bash
make auto STATE=on
# wait 30 seconds
make auto STATE=off
```

What happens:

- The merchant sends one payment every 3 seconds with a random `order_id`.
- Logs grow quickly.
- Pending counts, callback rates, and daily reports change.

Use this to practise filtering noise:

```bash
jq -r 'select(.msg == "payment_initiated") | .channel' logs/aggregator/app.log \
  | sort | uniq -c
```

## Recovery

After any scenario:

```bash
make telco MODE=normal
make merchant MODE=ok
make auto STATE=off
```

If you want the original seed puzzles back:

```bash
make reset
```

## Combining failures

Some realistic incidents need two switches:

```bash
# Telco settles but callback is dropped; merchant webhook is also broken.
make telco MODE=drop_callback
make merchant MODE=500_crash
make fire N=1

# Restore both and retry the webhook by hand.
make telco MODE=normal
make merchant MODE=ok
make retry TRX=trx_replace_me
```

Observe which symptom masks which: a transaction with no callback will never
reach the merchant, so the merchant failure is invisible until you replay the
telco callback.
