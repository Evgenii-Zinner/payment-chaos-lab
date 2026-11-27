# Logs: where they are and how to read them

This lab writes to plain files on the host. That is deliberate: you can use
`grep`, `jq`, `awk`, `less`, and `tail` before you touch a log platform. Promtail
ships the same files to Loki for Grafana.

## Locations

| Service | Host file | Container file | Notes |
|---|---|---|---|
| Aggregator | `logs/aggregator/app.log` | `/logs/app.log` | JSON lines, UTC ISO timestamps |
| Telco | `logs/telco/telco.log` | `/logs/telco.log` | JSON lines; only chaos events and errors on the happy path |
| Merchant | `logs/merchant/merchant.log` | `/logs/merchant.log` | JSON lines with `event`, `mode`, `body` |
| nginx access | `logs/nginx/access.log` | `/var/log/nginx/access.log` | combined format |
| nginx error | `logs/nginx/error.log` | `/var/log/nginx/error.log` | nginx error format |

The host files are bind-mounted into the containers. Deleting a file while a
service is running can make the service keep writing to the deleted inode; stop
the stack first, or use `make reset`.

## Follow logs

```bash
make tail                 # every file under logs/
make logs-agg             # aggregator only
make logs-telco
make logs-merchant
make logs-nginx

tail -f logs/aggregator/app.log
tail -f logs/aggregator/app.log logs/merchant/merchant.log
```

Container stdout/stderr is separate:

```bash
make logs
docker compose logs -f aggregator
docker compose logs --tail=100 telco
docker compose logs --since=10m merchant
```

## Aggregator format

One JSON object per line:

```json
{"ts": "2026-11-25T18:48:29.308733+00:00", "level": "INFO", "service": "aggregator", "msg": "telco_callback_processed", "transaction_id": "trx_8f18a41210", "status": "success"}
```

### Message catalogue

| `msg` | Level | Context keys | What it means |
|---|---|---|---|
| `payment_initiated` | INFO | `transaction_id`, `merchant_id`, `channel`, `order_id` | Payment inserted as pending and sent to telco |
| `duplicate_retry_storm` | WARN | `merchant_id`, `order_id` | Redis idempotency lock rejected the request |
| `missing_bearer` | WARN | none | No `Authorization: Bearer ...` header |
| `invalid_token` | WARN | `token_prefix` | Token not found in `merchants` |
| `invalid_json_body` | WARN | none | Body was not valid JSON |
| `upstream_timeout` | ERROR | `transaction_id`, `channel` | Telco call timed out; transaction marked failed |
| `upstream_5xx` | ERROR | `transaction_id`, `channel`, `status_code` | Telco returned 5xx; transaction marked failed |
| `telco_callback_processed` | INFO | `transaction_id`, `status` | Telco callback updated the transaction |
| `telco_callback_parse_error` | ERROR | `error`, `raw` | Callback body did not match the expected schema |
| `webhook_attempt` | INFO/WARN | `transaction_id`, `attempt`, `http_code`, `body` | One merchant webhook attempt; WARN when not 200 |

## Merchant format

```json
{"event": "webhook_received", "mode": "ok", "body": "{\"transactionId\":\"trx_...\",\"status\":\"success\"}"}
```

`mode` is the current merchant webhook switch (`ok`, `403_waf`, `302_redirect`,
`500_crash`, `bad_hmac`). The merchant logs the request before applying the
mode, so you can see the body even when it returns an error.

## Telco format

On the happy path the telco writes little or nothing. Chaos events are explicit:

```json
{"msg": "CHAOS_DROPPED_CALLBACK", "external_ref": "trx_65add440aa"}
```

Use the aggregator log for the callback that never arrived, and the
`provider_settlements` table for proof that the telco settled.

## nginx format

Access log (combined):

```
172.18.0.7 - - [25/Nov/2026:18:48:27 +0000] "POST /api/v1/payments/collect HTTP/1.1" 200 53 "-" "python-httpx/0.28.1"
```

Fields: client IP, identity, user, timestamp, request, status, bytes, referer,
user agent. The status is field 9 in `awk`.

Error log:

```
2026/11/25 19:52:06 [error] 22#22: *41 upstream timed out (110: Connection timed out) while reading response header from upstream
```

## Command-line recipes

### Pretty-print a file

```bash
jq . logs/aggregator/app.log | less
```

### Only errors and warnings

```bash
jq -c 'select(.level == "ERROR" or .level == "WARN")' logs/aggregator/app.log
```

### Count log messages

```bash
jq -r '.msg // .event' logs/aggregator/app.log | sort | uniq -c | sort -nr
```

### Trace one transaction everywhere

```bash
grep -F 'trx_seed_003' logs/aggregator/app.log | jq -c .
grep -F 'trx_seed_003' logs/merchant/merchant.log | jq -c .
```

### Every webhook attempt with its result

```bash
jq -r 'select(.msg == "webhook_attempt") | [.ts, .transaction_id, .attempt, .http_code] | @tsv' \
  logs/aggregator/app.log
```

### Webhook status code histogram

```bash
jq -r 'select(.msg == "webhook_attempt") | .http_code' logs/aggregator/app.log \
  | sort | uniq -c | sort -nr
```

### Slow/failed upstream calls

```bash
jq -c 'select(.msg == "upstream_timeout" or .msg == "upstream_5xx")' \
  logs/aggregator/app.log
```

### Follow only new webhook attempts

```bash
tail -f logs/aggregator/app.log | jq -c 'select(.msg == "webhook_attempt")'
```

### Find 5xx responses in nginx

```bash
awk '$9 ~ /^5/ {print}' logs/nginx/access.log
```

### Count nginx status codes

```bash
awk '{print $9}' logs/nginx/access.log | sort | uniq -c | sort -nr
```

### Find upstream timeouts in nginx

```bash
grep -i 'timed out' logs/nginx/error.log
```

## Loki and Grafana

Promtail labels each stream with `service`:

- `service="aggregator"`
- `service="telco"`
- `service="merchant"`
- `service="nginx"`

In Grafana: **Explore → Loki**.

### Basic queries

```logql
{service="aggregator"}
{service="aggregator"} |= "ERROR"
{service="aggregator"} |= "payment_initiated"
{service=~"aggregator|telco|merchant"} |~ "ERROR|WARN|CHAOS"
{service="nginx"} |~ " 5[0-9][0-9] "
```

### Parse JSON fields

```logql
{service="aggregator"} | json | msg="webhook_attempt"
{service="aggregator"} | json | level="ERROR"
{service="merchant"} | json | event="webhook_received"
```

### Count over time

```logql
sum(count_over_time({service="aggregator"} |= "ERROR" [5m]))
sum by (service) (count_over_time({service=~".+"} |~ "ERROR|WARN" [5m]))
```

### Filter by transaction id

```logql
{service="aggregator"} |= "trx_seed_003"
```

### Direct Loki API

```bash
curl -sG 'http://localhost:3100/loki/api/v1/query_range' \
  --data-urlencode 'query={service="aggregator"}' \
  --data-urlencode 'limit=20' \
  --data-urlencode 'start=1h' | jq .
```

## Common pitfalls

- **Empty Grafana panels.** Widen the time range to **Last 24 hours**; the lab
  may have been idle. Generate traffic with `make fire N=5`.
- **No logs at all.** Check `ls -l logs/*/*.log` and
  `docker compose logs --tail=100 promtail loki`.
- **Timestamps look shifted.** Aggregator and callback times are UTC. Telco
  settlement times are UTC+3. Convert before comparing.
- **The file is huge.** Auto-traffic writes one payment every 3 seconds. Turn it
  off with `make auto STATE=off`, or reset with `make reset`.
- **`jq` says “Invalid numeric literal”.** You are probably reading the nginx
  access log, which is not JSON. Use `awk`/`grep` for nginx.
- **`tail` shows nothing after a restart.** The file may have been recreated;
  use `tail -F` (capital F) to follow across rotation/recreation.
- **Docker logs are not the same as file logs.** `docker compose logs` shows
  stdout/stderr; `logs/*.log` shows the application’s own file output. The
  aggregator writes its JSON events to both; the merchant and telco write their
  JSON events to files only (uvicorn still logs requests to stdout).
