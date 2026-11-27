# Lab 5 — Webhook failures

**Goal:** separate payment status from notification status, and practise
diagnosing merchant-side webhook failures.

**Time:** 25 minutes.

## Setup

```bash
make auto STATE=off
make telco MODE=normal
make merchant MODE=ok
```

## Scenario A — 403 WAF block

```bash
make merchant MODE=403_waf
ORDER="ord_wh403_$(date +%s)"
make pay ORDER="$ORDER"
make merchant MODE=ok
```

Wait 3 seconds.

```sql
SELECT transaction_id, order_id, status
FROM transactions
WHERE order_id = '<your order_id>';

SELECT transaction_id, attempt, http_code, response_body, sent_at
FROM callbacks_log
WHERE transaction_id = '<your transaction_id>'
ORDER BY attempt;
```

Expected:

- `transactions.status = 'success'` — the customer paid.
- Two callback rows, both `403`.
- The merchant did not accept the notification.

Logs:

```bash
jq -c 'select(.msg == "webhook_attempt")' logs/aggregator/app.log | tail -2
```

## Scenario B — merchant 500

```bash
make merchant MODE=500_crash
ORDER="ord_wh500_$(date +%s)"
make pay ORDER="$ORDER"
make merchant MODE=ok
```

Wait 3 seconds, then query the callbacks. Expected: two `500` rows.

Now recover the notification:

```bash
make retry TRX=trx_replace_me
```

Query again:

```sql
SELECT transaction_id, attempt, http_code, response_body, sent_at
FROM callbacks_log
WHERE transaction_id = '<your transaction_id>'
ORDER BY attempt;
```

Expected: a third row with `200`.

## Scenario C — redirect

```bash
make merchant MODE=302_redirect
ORDER="ord_wh302_$(date +%s)"
make pay ORDER="$ORDER"
make merchant MODE=ok
```

Expected: two callback rows with `302`. The aggregator does not follow
redirects, because a webhook endpoint that redirects is usually misconfigured
or malicious.

## Scenario D — bad HMAC

```bash
make merchant MODE=bad_hmac
ORDER="ord_whhmac_$(date +%s)"
make pay ORDER="$ORDER"
make merchant MODE=ok
```

Expected: two callback rows with `400` and `response_body` mentioning the
signature.

## Find everything that needs attention

```sql
-- Transactions with at least one failed callback attempt
SELECT t.transaction_id, t.order_id, t.status,
       COUNT(c.id) AS attempts,
       SUM(c.http_code >= 400 OR c.http_code IS NULL) AS failures,
       MAX(c.http_code = 200) AS eventually_ok
FROM transactions t
JOIN callbacks_log c ON c.transaction_id = t.transaction_id
GROUP BY t.id, t.transaction_id, t.order_id, t.status
HAVING failures > 0
ORDER BY t.id DESC;

-- Transactions with no successful callback at all
SELECT t.transaction_id, t.order_id, t.status
FROM transactions t
WHERE t.status = 'success'
  AND NOT EXISTS (
      SELECT 1 FROM callbacks_log c
      WHERE c.transaction_id = t.transaction_id AND c.http_code = 200
  )
ORDER BY t.id DESC;
```

## Inspect the signature (optional)

The aggregator signs the raw JSON body with HMAC-SHA256 using
`merchants.hmac_secret`. You can reproduce it:

```bash
python3 - <<'PY'
import hashlib, hmac, json
payload = json.dumps({
    "transactionId": "trx_example",
    "orderId": "ord_example",
    "status": "success",
    "amount": 250.0,
    "currency": "ZMW",
}, separators=(",", ":"))
secret = "sec_zoyk_hmac"
print(payload)
print(hmac.new(secret.encode(), payload.encode(), hashlib.sha256).hexdigest())
PY
```

The merchant compares this with the `X-Signature` header. A mismatch returns
400.

## Questions

1. The payment is `success` but every callback is 500. Is the customer paid?
2. Is the merchant’s order updated? How would you know?
3. Which retry policy makes sense: fixed interval, exponential backoff, or
   manual?
4. What should happen after the retry budget is exhausted?
5. Why is a 302 not a success?
6. What is the difference between a 400 (bad signature) and a 403 (blocked)?

## Cleanup

```bash
make merchant MODE=ok
make telco MODE=normal
```
