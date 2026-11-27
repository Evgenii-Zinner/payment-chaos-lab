# Lab 1 — First payment, end to end

**Goal:** send one payment and trace it through every component.

**Time:** 15 minutes.

## Setup

```bash
make up
make auto STATE=off
make telco MODE=normal
make merchant MODE=ok
```

## Send a payment

```bash
ORDER="ord_lab1_$(date +%s)"
echo "$ORDER"
make pay ORDER="$ORDER"
```

The response looks like:

```json
{"transactionId":"trx_ab12cd34ef","status":"pending"}
```

Write down the `transactionId`. You will use it everywhere.

## Follow it through the system

### 1. nginx saw the request

```bash
tail -n 20 logs/nginx/access.log
```

Find the `POST /api/v1/payments/collect` line with status 200.

### 2. The aggregator accepted it

```bash
jq -c 'select(.msg == "payment_initiated")' logs/aggregator/app.log | tail -1
```

You should see your `order_id`, the channel, and the new `transaction_id`.

### 3. The telco settled it

```sql
SELECT *
FROM provider_settlements
ORDER BY id DESC
LIMIT 1;
```

Note the `settled_at_eat` value. It is UTC+3, not UTC.

### 4. The aggregator processed the callback

```bash
jq -c 'select(.msg == "telco_callback_processed")' logs/aggregator/app.log | tail -1
```

### 5. The merchant received the webhook

```bash
jq -c 'select(.event == "webhook_received")' logs/merchant/merchant.log | tail -1
```

### 6. The database agrees

```sql
SELECT transaction_id, order_id, status, amount, provider_fee, created_at
FROM transactions
WHERE order_id = '<your order_id>';

SELECT transaction_id, attempt, http_code, response_body, sent_at
FROM callbacks_log
WHERE transaction_id = '<your transaction_id>';
```

Expected: one `transactions` row with `status = 'success'`, one callback row
with `http_code = 200`, and one settlement row.

## Questions

1. Which component generated the `transaction_id`?
2. Which component generated the `provider_tx_id`?
3. Why is `created_at` different from `settled_at_eat` even for the same
   payment?
4. What would the merchant see if the webhook failed but the payment succeeded?
5. Which table would you check first if a customer said “I paid but the order
   is still pending”?

## Cleanup

Leave the switches in `normal`/`ok`; they are already there.
