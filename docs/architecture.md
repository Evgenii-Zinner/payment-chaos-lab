# Architecture and request flows

The lab has four moving parts that matter:

- **Merchant simulator** — a customer system that sends payments and receives
  webhooks.
- **Aggregator** — the payment platform. It owns the transaction record and the
  merchant-facing API.
- **Telco mock** — an upstream mobile-money provider. It settles independently
  and calls back asynchronously.
- **MariaDB + Redis** — the transaction store and the short-lived coordination
  layer.

nginx sits in front of the aggregator so you can see proxy timeouts and HTTP
status codes in a realistic place.

## Components

| Component | Responsibility | State |
|---|---|---|
| Merchant | Generate traffic; validate HMAC; expose webhook failure switches | Redis `chaos:merchant_wh`, `chaos:auto_traffic` |
| nginx | Reverse proxy; access/error logs; 4s read timeout | none |
| Aggregator | Auth, idempotency, transaction lifecycle, telco call, merchant webhook | MariaDB `transactions`, `callbacks_log`; Redis idempotency keys |
| Telco | Accept STK push; settle; call back; expose settlement CSV | MariaDB `provider_settlements`; Redis `chaos:telco_mode` |
| Promtail/Loki/Grafana | Log collection, storage, search | Loki filesystem (ephemeral) |
| Adminer | Browser SQL client | none |

## Flow 1 — a merchant collects a payment

```
Merchant simulator
  POST http://nginx:80/api/v1/payments/collect
  Authorization: Bearer tok_zoyk_live_42
  {order_id, amount, currency, channel, phone}
        |
        v
nginx :8080
        |
        v
Aggregator
  1. Validate Bearer token against merchants.api_token
  2. Validate required JSON fields
  3. Redis SET NX idem:{merchant_id}:{order_id} EX 10
  4. INSERT transactions (... status='pending', created_at=UTC_TIMESTAMP())
  5. POST http://telco:8003/stkpush
        |
        v
Telco
  6. Return {"accepted": true} immediately
  7. Background task: sleep 1s, INSERT provider_settlements (settled_at_eat = UTC+3)
  8. POST http://nginx:80/api/v1/webhooks/telco
```

The aggregator returns `{"transactionId": "...", "status": "pending"}` as soon
as the telco accepts the push. It does not wait for settlement.

### What can go wrong here

- Missing or invalid Bearer token → 401; aggregator logs `missing_bearer` or
  `invalid_token`.
- Malformed JSON → 400; `invalid_json_body`.
- Missing field → 400; FastAPI validation.
- Same `order_id` inside the 10s window → 409; `duplicate_retry_storm`.
- Telco timeout → aggregator marks `failed` with `TELCO_TIMEOUT`, sleeps 5s to
  force nginx’s 4s read timeout, client sees 504.
- Telco 5xx → aggregator marks `failed` with `TELCO_<code>`, client sees 502.

## Flow 2 — the telco calls back

```
Telco background task
  POST http://nginx:80/api/v1/webhooks/telco
  {external_ref, status, fee}
        |
        v
Aggregator
  1. Parse JSON; on failure log telco_callback_parse_error and return 400
  2. UPDATE transactions SET status=?, provider_fee=? WHERE transaction_id=?
  3. Log telco_callback_processed
  4. Background task: deliver merchant webhook
  5. Return {"ok": true}
```

The telco callback is the moment the platform learns the payment succeeded. If
this call is dropped or malformed, the transaction stays `pending` even though
the telco settled it. That is the core reconciliation exercise.

## Flow 3 — the aggregator calls the merchant

```
Aggregator background task
  SELECT transaction + merchant.webhook_url + merchant.hmac_secret
  Build compact JSON payload
  HMAC-SHA256(payload, hmac_secret) -> X-Signature
  For attempt in (1, 2):
      POST merchant.webhook_url
      INSERT callbacks_log (transaction_id, attempt, http_code, body, sent_at)
      if 200 and body contains "ok": break
```

The payload is:

```json
{"transactionId":"trx_...","orderId":"ord_...","status":"success","amount":250.0,"currency":"ZMW"}
```

The merchant validates the HMAC. Chaos modes can return 403, 302, 500, or 400
before or instead of that validation.

## Data ownership and timestamps

| Data | Owner | Timestamp convention |
|---|---|---|
| Payment intent and status | Aggregator (`transactions`) | UTC |
| Merchant webhook attempts | Aggregator (`callbacks_log`) | UTC |
| Telco settlement | Telco (`provider_settlements`) | East Africa Time (UTC+3) |
| HTTP request log | nginx | UTC in the default image |

The timezone difference is deliberate. A payment at 22:30 UTC on 24 November is
01:30 EAT on 25 November. Daily reports built from different tables will
disagree unless you normalise.

## Idempotency

The aggregator uses a short Redis lock:

```text
key: idem:{merchant_id}:{order_id}
value: 1
TTL: 10 seconds
```

`SET NX` means only the first request wins. A retry storm with the same
`order_id` gets 409 and a `duplicate_retry_storm` log line. After 10 seconds the
key expires, so a later retry can create a second transaction. The seed data
also contains a duplicate `order_id` (`ord_dup_1`) with one success and one
failure, so you can practise finding duplicates that already exist.

## Why nginx is in the path

- It gives you a realistic reverse-proxy hop and a separate access log.
- Its `proxy_read_timeout 4s` turns a slow telco into a visible 504.
- It is the single public entry point (`:8080`) for the aggregator, which makes
  the merchant → platform boundary clear.
- The aggregator is still reachable directly on `:8000` for debugging.

## Failure domains

| Failure | Blast radius | Where it shows up |
|---|---|---|
| Telco slow | one request; nginx 504 | `upstream_timeout`, nginx access 504 |
| Telco 5xx | one request; aggregator 502 | `upstream_5xx`, transaction `failed` |
| Telco drops callback | transaction stays pending forever | no `telco_callback_processed`; settlement exists |
| Telco malformed callback | transaction stays pending | `telco_callback_parse_error` |
| Merchant WAF/500 | webhook retries; transaction still success | `callbacks_log` 403/500 |
| Merchant redirect | webhook treated as failure | `callbacks_log` 302 |
| Bad HMAC | merchant rejects callback | `callbacks_log` 400 |
| Duplicate order | 409 or duplicate rows | `duplicate_retry_storm`, duplicate `order_id` |
| Redis down | idempotency unavailable; app errors | aggregator 500 / connection errors |

## Extension points

- Add Prometheus metrics to the FastAPI services and a Grafana dashboard.
- Add OpenTelemetry tracing to follow one `transaction_id` across services.
- Add a dead-letter table for callbacks that exhaust retries.
- Add a reconciliation job that compares `transactions` with
  `provider_settlements` and flags mismatches.
- Add a refund flow and a second upstream provider.
