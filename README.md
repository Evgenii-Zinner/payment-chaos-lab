# Payment Chaos Lab

A local, disposable payments lab for learning how a fintech platform behaves when
merchants, a telco upstream, webhooks, queues, and a database disagree with each
other.

You get a working payment flow, a set of chaos switches, structured logs, a SQL
database, and dashboards. Break it on purpose, then use the logs and SQL to work
out what happened.

Everything here is fake. Do not put real customer, card, phone, or merchant data
into the lab.

---

## What you can practise

- Follow one payment from merchant request to telco settlement and back.
- Read application, webhook, and nginx logs, and know which file is which.
- Write SQL to find stuck payments, duplicate orders, missing callbacks, and
  reconciliation breaks.
- Reproduce common production failures: upstream timeout, upstream 5xx, dropped
  callback, malformed callback, WAF block, redirect, merchant 500, bad HMAC.
- Compare UTC timestamps with East Africa Time (UTC+3).
- Use Grafana/Loki to search logs and Grafana/MySQL to query the database.
- Reset the whole lab and try again.

---

## Architecture

```
                         Bearer token + JSON
  ┌──────────────────┐   POST /api/v1/payments/collect   ┌──────────────┐
  │ Merchant          │ ────────────────────────────────▶ │ nginx :8080  │
  │ simulator :8001   │                                   └──────┬───────┘
  └────────▲─────────┘                                          │ proxy
           │                                                    ▼
           │  webhook (HMAC)                            ┌──────────────┐
           │  POST /webhook                             │ Aggregator   │
           └────────────────────────────────────────────│ :8000        │
                                                        └──┬────────┬──┘
                                                           │        │
                                     POST /stkpush         │        │ SQL
                                                           ▼        ▼
                                                    ┌──────────┐  ┌─────────┐
                                                    │ Telco    │  │ MariaDB │
                                                    │ mock     │  │ :3306   │
                                                    │ :8003    │  └─────────┘
                                                    └────┬─────┘
                                                         │ callback
                                                         │ POST /api/v1/webhooks/telco
                                                         ▼
                                                   nginx -> aggregator
```

Supporting pieces:

- **Redis** stores chaos switches and the short idempotency lock.
- **Promtail** tails the log files and ships them to **Loki**.
- **Grafana** reads Loki and MariaDB.
- **Adminer** is a browser SQL workbench.

The aggregator is the source of truth for a payment. The telco is an external
provider that settles independently. The merchant is a customer system that
receives webhooks. Most bugs in the lab come from those three views disagreeing.

---

## Services and ports

| Service | URL / port | What it is |
|---|---|---|
| Merchant simulator | http://localhost:8001 | Sends payments; receives webhooks; has chaos buttons |
| Telco mock | http://localhost:8003 | Accepts STK push; settles; sends callbacks; has chaos buttons |
| Aggregator through nginx | http://localhost:8080 | Host `8080` → nginx `80` → aggregator `8000`; the realistic API entry point, with nginx access logs and timeouts |
| Aggregator direct | http://localhost:8000 | Host `8000` → aggregator `8000`; bypasses nginx, useful for debugging the app itself |
| Grafana | http://localhost:3000 | Logs + SQL dashboards (admin / admin) |
| Adminer | http://localhost:8081 | Browser SQL workbench |
| MariaDB | localhost:3306 | Database `payments_lab`, user `root`, password `rootpass` |
| Loki API | http://localhost:3100 | Log store behind Grafana |
| Redis | internal | Chaos switches + idempotency keys |

Container names are prefixed with `lab_` (`lab_db`, `lab_aggregator`,
`lab_telco`, `lab_merchant`, `lab_nginx`, `lab_grafana`, `lab_adminer`,
`lab_loki`, `lab_promtail`, `lab_redis`).

---

## Prerequisites

Required:

- Docker Engine 24+ with Docker Compose v2 (`docker compose version`)
- `make`
- `curl`

Recommended:

- `jq` for reading JSON logs on the command line
- A browser for Grafana and Adminer

Optional desktop tools are listed in [What else you can add](#what-else-you-can-add).

Make sure these host ports are free: `3000`, `3306`, `8000`, `8001`, `8003`,
`8080`, `8081`, `3100`.

---

## Quick start

```bash
# from the repository root
make up          # build images and start everything
make smoke       # wait for services, send one payment, show the log tail
make urls        # print all URLs
```

`make up` starts the stack in the background. The first build takes a minute or
two. MariaDB runs `db/01_init.sql` only when its volume is empty, so the first
start also seeds the demo data.

> If you have run an older version of this lab, run `make reset` once. The
> database name and schema are created only on an empty volume.

Open these in a browser:

1. http://localhost:8001 — merchant simulator
2. http://localhost:8003 — telco mock and chaos panel
3. http://localhost:3000 — Grafana (`admin` / `admin`), then **Dashboards →
   Payment Lab → Payment Lab Overview**
4. http://localhost:8081 — Adminer (system **MySQL**, server `db`, user `root`,
   password `rootpass`, database `payments_lab`)
5. http://localhost:8080/docs — the aggregator API

---

## First 10 minutes

This is the shortest path to seeing the whole system work.

1. **Start clean**

   ```bash
   make reset      # only if you want to wipe old data; otherwise skip
   make up
   make smoke
   ```

2. **Watch the files while a payment runs**

   In one terminal:

   ```bash
   make tail
   ```

   In another terminal:

   ```bash
   make fire N=1
   ```

   You should see:
   - merchant log: `webhook_received`
   - nginx access log: `POST /api/v1/payments/collect`
   - aggregator log: `payment_initiated`, then `telco_callback_processed`,
     then `webhook_attempt`
   - telco log: usually quiet on success; chaos events appear here

3. **Find the payment in SQL**

   ```bash
   make sql
   ```

   ```sql
   SELECT transaction_id, order_id, status, amount, provider_fee, created_at
   FROM transactions
   ORDER BY id DESC
   LIMIT 5;

   SELECT * FROM callbacks_log ORDER BY id DESC LIMIT 5;
   SELECT * FROM provider_settlements ORDER BY id DESC LIMIT 5;
   ```

   Exit with `\q`.

4. **Find the same payment in Grafana**

   - Go to **Explore**.
   - Pick the **Loki** datasource.
   - Run `{service="aggregator"}`.
   - Filter with `{service="aggregator"} |= "payment_initiated"`.
   - Pick the **PaymentsMySQL** datasource and run the same SQL.

5. **Break something**

   ```bash
   make telco MODE=drop_callback
   make fire N=1
   make telco MODE=normal
   ```

   Then look for a transaction that is `pending` in `transactions` but has a
   `SUCCESS` row in `provider_settlements`. That is the reconciliation bug.

---

## Where the logs are

There are two ways to read logs: the files on the host, and the container log
stream. The files are the primary source for this lab because they are easy to
`grep`, `jq`, and ship to Loki.

### Host files

| File | Written by | Format |
|---|---|---|
| `logs/aggregator/app.log` | aggregator | one JSON object per line |
| `logs/telco/telco.log` | telco mock | JSON objects (success path is quiet) |
| `logs/merchant/merchant.log` | merchant simulator | JSON objects |
| `logs/nginx/access.log` | nginx | combined access log |
| `logs/nginx/error.log` | nginx | nginx error log |

### Container paths

| Host path | Container path |
|---|---|
| `logs/aggregator/` | `/logs` in `lab_aggregator` |
| `logs/telco/` | `/logs` in `lab_telco` |
| `logs/merchant/` | `/logs` in `lab_merchant` |
| `logs/nginx/` | `/var/log/nginx` in `lab_nginx` |

### Commands

```bash
make tail                 # follow every file under logs/
make logs-agg             # follow logs/aggregator/app.log
make logs-telco           # follow logs/telco/telco.log
make logs-merchant        # follow logs/merchant/merchant.log
make logs-nginx           # follow logs/nginx/*.log

make logs                 # docker compose logs -f (stdout/stderr)
docker compose logs -f aggregator
docker compose logs --tail=100 telco
```

### Log fields

Aggregator JSON lines look like this:

```json
{"ts":"2026-11-25T18:48:29.308733+00:00","level":"INFO","service":"aggregator","msg":"telco_callback_processed","transaction_id":"trx_8f18a41210","status":"success"}
```

Important `msg` values:

| `msg` | Meaning |
|---|---|
| `payment_initiated` | merchant request accepted, transaction inserted as `pending` |
| `duplicate_retry_storm` | same merchant + order_id hit the Redis idempotency lock |
| `upstream_timeout` | telco did not answer before the aggregator timeout |
| `upstream_5xx` | telco returned 5xx |
| `telco_callback_processed` | telco callback updated the transaction |
| `telco_callback_parse_error` | callback body was malformed |
| `webhook_attempt` | one merchant webhook delivery attempt |
| `missing_bearer` / `invalid_token` | authentication failure |
| `invalid_json_body` | request body was not JSON |

Merchant lines use `event` rather than `msg`:

```json
{"event":"webhook_received","mode":"ok","body":"{\"transactionId\":\"trx_...\",\"status\":\"success\"}"}
```

Nginx access lines are standard combined format:

```
172.18.0.7 - - [25/Nov/2026:18:48:27 +0000] "POST /api/v1/payments/collect HTTP/1.1" 200 53 "-" "python-httpx/0.28.1"
```

See [docs/logs.md](docs/logs.md) for `jq` recipes, Loki queries, and a field
reference.

---

## Controlling the lab

All chaos switches are runtime settings stored in Redis. They survive a service
restart but not `make reset` (which deletes the database volume; Redis is
ephemeral in this lab).

### Merchant traffic

```bash
make auto STATE=off        # turn off background traffic (it is off by default)
make auto STATE=on         # turn on one payment every 3 seconds
make fire N=10             # send 10 payments with random order_ids
make fire N=3 DUP=1        # send the same order_id 3 times (retry storm)
make pay ORDER=ord_manual_1
```

### Telco chaos

```bash
make telco MODE=normal
make telco MODE=timeout
make telco MODE=503
make telco MODE=drop_callback
make telco MODE=bad_format
```

| Mode | What happens | What to look for |
|---|---|---|
| `normal` | STK push accepted, callback sent after ~1s | transaction becomes `success`; callback row with 200 |
| `timeout` | telco sleeps 6s | aggregator logs `upstream_timeout`; nginx returns 504; transaction `failed` with `TELCO_TIMEOUT` |
| `503` | telco returns 503 | aggregator logs `upstream_5xx`; client gets 502; transaction `failed` with `TELCO_503` |
| `drop_callback` | telco settles but never calls the aggregator | transaction stays `pending`; settlement exists with `SUCCESS` |
| `bad_format` | callback uses the wrong JSON schema | aggregator logs `telco_callback_parse_error`; transaction stays `pending` |

### Merchant webhook chaos

```bash
make merchant MODE=ok
make merchant MODE=403_waf
make merchant MODE=302_redirect
make merchant MODE=500_crash
make merchant MODE=bad_hmac
```

| Mode | What happens | What to look for |
|---|---|---|
| `ok` | webhook accepted | `callbacks_log.http_code = 200` |
| `403_waf` | merchant pretends a WAF blocked the call | `http_code = 403`; two attempts |
| `302_redirect` | merchant redirects | `http_code = 302`; redirects are not followed |
| `500_crash` | merchant database is “down” | `http_code = 500`; two attempts |
| `bad_hmac` | merchant rejects the signature | `http_code = 400` |

### Retry a webhook by hand

```bash
make retry TRX=trx_seed_003
```

This calls the aggregator’s manual retry endpoint and adds new rows to
`callbacks_log`.

### Other useful commands

```bash
make status              # service health + URLs
make settlements         # download the telco CSV to ./telco_settlements_eat.csv
make ps                  # container status
make down                # stop, keep the database volume
make reset               # wipe database + logs, rebuild
```

### Under the hood (manual commands)

`make` is just a thin shortcut layer over `docker compose` and `scripts/*.sh`. If
you prefer to run the underlying commands directly (or inspect them in
[Makefile](Makefile), [scripts/chaos.sh](scripts/chaos.sh), and
[scripts/sql.sh](scripts/sql.sh)):

```bash
# Stack lifecycle
docker compose up -d --build
docker compose ps
docker compose down

# SQL shell and one-off query
docker compose exec db mariadb -uroot -prootpass payments_lab
docker compose exec -T db mariadb -uroot -prootpass payments_lab -e "SELECT status, COUNT(*) FROM transactions GROUP BY status"

# Send a payment (same as: make pay ORDER=ord_manual_1)
curl -sS -X POST http://localhost:8080/api/v1/payments/collect \
  -H "Authorization: Bearer tok_zoyk_live_42" \
  -H "Content-Type: application/json" \
  -d '{"order_id":"ord_manual_1","amount":250,"currency":"ZMW","channel":"MTN_ZM","phone":"260971112233"}'

# Retry a merchant webhook (same as: make retry TRX=trx_seed_003)
curl -fsS -X POST http://localhost:8080/api/v1/webhooks/retry/trx_seed_003

# Chaos switches & traffic (same as: make telco / merchant / auto / fire / settlements)
curl -fsS -X POST http://localhost:8003/chaos/timeout
curl -fsS -X POST http://localhost:8001/chaos/500_crash
curl -fsS -X POST http://localhost:8001/auto/on
curl -fsS -X POST "http://localhost:8001/fire/3?duplicate=true"
curl -fsS http://localhost:8003/settlements/csv -o telco_settlements_eat.csv
```

---

## SQL workbench

Use any of these:

- **Adminer** (included): http://localhost:8081
  - System: `MySQL`
  - Server: `db`
  - Username: `root`
  - Password: `rootpass`
  - Database: `payments_lab`
- **CLI**:

  ```bash
  make sql
  make q Q="SELECT status, COUNT(*) FROM transactions GROUP BY status"
  ```

- **Desktop client** (DBeaver, TablePlus, DataGrip, HeidiSQL, SQL Workbench/J):
  - Host: `127.0.0.1`
  - Port: `3306`
  - Database: `payments_lab`
  - User: `root`
  - Password: `rootpass`

### Schema at a glance

| Table | Purpose |
|---|---|
| `merchants` | merchant id, API token, HMAC secret, webhook URL, commission % |
| `transactions` | one row per payment; `status` is `pending`, `success`, or `failed`; timestamps are UTC |
| `callbacks_log` | every merchant webhook attempt: attempt number, HTTP code, response body, UTC time |
| `provider_settlements` | telco settlement records; timestamps are East Africa Time (UTC+3) |

Run the guided queries in:

- `db/queries/01_warmup.sql`
- `db/queries/02_investigations.sql` (questions)
- `db/queries/03_answers.sql` (answers)

See [docs/sql-workbench.md](docs/sql-workbench.md) for connection details,
query patterns, and the reconciliation queries.

---

## Seed data mysteries

`db/01_init.sql` seeds a handful of rows that are deliberately inconsistent. On a
fresh reset, with auto-traffic off, these are the puzzles:

| Transaction | Puzzle |
|---|---|
| `trx_seed_002` | `success` but `provider_fee` is NULL |
| `trx_seed_003` | first webhook attempt 500, second 200 |
| `trx_seed_004` | `success` but no callback row |
| `trx_seed_005` | `pending` here, but `SUCCESS` in `provider_settlements` |
| `trx_seed_006` | `failed` with `TELCO_504` |
| `trx_seed_007` / `trx_seed_008` | same `order_id` (`ord_dup_1`), one success, one duplicate failure; `trx_seed_007` also has no callback |
| `trx_seed_009` | 22:30 UTC = 01:30 next day in UTC+3; commission mismatch |

The lab’s job is to make you comfortable finding these without guessing.

---

## Learning path

Work through the labs in order, or jump to the failure you care about:

1. [Lab 1 — First payment, end to end](docs/labs/01-first-payment.md)
2. [Lab 2 — Read the logs](docs/labs/02-read-the-logs.md)
3. [Lab 3 — SQL basics](docs/labs/03-sql-basics.md)
4. [Lab 4 — Stuck payments](docs/labs/04-stuck-payments.md)
5. [Lab 5 — Webhook failures](docs/labs/05-webhook-failures.md)
6. [Lab 6 — Reconciliation and time zones](docs/labs/06-reconciliation-timezone.md)
7. [Lab 7 — Load, duplicates, and idempotency](docs/labs/07-load-idempotency.md)

Deep dives:

- [Architecture and request flows](docs/architecture.md)
- [Logs: files, fields, jq, Loki](docs/logs.md)
- [SQL workbench and query patterns](docs/sql-workbench.md)
- [Chaos playbook](docs/chaos-playbook.md)
- [Instructor guide](docs/instructor-guide.md)

---

## Reset and troubleshooting

### Reset everything

```bash
make reset
```

This runs `docker compose down -v`, deletes every `*.log` under `logs/`, and
rebuilds. The seed data is applied again.

### The database is empty or the schema is old

MariaDB only runs `db/01_init.sql` when its volume is empty. If you changed the
SQL file, run:

```bash
make reset
```

### A port is already in use

Edit the host side of the port mapping in `docker-compose.yml`, then update the
URLs in this README, `Makefile`, `scripts/`, and the Grafana dashboard if
needed. Common conflicts are `3000` (another Grafana), `3306` (a local MySQL),
and `8080` (another web server).

### Grafana shows no logs

1. Check that files exist: `ls -l logs/*/*.log`.
2. Check Promtail: `docker compose logs --tail=100 promtail`.
3. Check Loki: `docker compose logs --tail=100 loki`.
4. In Grafana Explore, use `{service="aggregator"}` and a wide time range
   (for example **Last 24 hours**).
5. Generate traffic: `make fire N=5`.

### Adminer cannot connect

Use server `db`, not `localhost`. Adminer runs inside the Compose network, so
`localhost` would mean the Adminer container itself.

### `make smoke` fails

```bash
make ps
docker compose logs --tail=100 db
docker compose logs --tail=100 aggregator
```

Wait for the MariaDB healthcheck before sending traffic. The first start can
take 10–20 seconds.

### Log files are owned by root

The containers run as root and may create root-owned files. If your user cannot
delete them, run:

```bash
sudo chown -R "$USER":"$USER" logs
```

### Everything is slow

The merchant simulator sends one payment every 3 seconds while auto-traffic is
on. Turn it off before doing careful SQL work:

```bash
make auto STATE=off
```

---

## What else you can add

The stack is intentionally small. **Already included:** Grafana, Loki, and
Adminer. Everything else in this table is optional and can be added without
changing the core payment flow.

| Tool | Why you might add it | How it fits |
|---|---|---|
| **Grafana** | Already included. Dashboards, Explore, alerts. | http://localhost:3000 |
| **Loki** | Already included. Log storage behind Grafana. | http://localhost:3100 |
| **Adminer** | Already included. Zero-install SQL workbench. | http://localhost:8081 |
| **DBeaver / TablePlus / DataGrip / HeidiSQL / SQL Workbench/J** | Desktop SQL clients with better autocomplete and export. | Connect to `127.0.0.1:3306` |
| **Prometheus** | Add metrics (request rate, latency, error rate) and Grafana metric panels. | Add `prometheus` + instrument the FastAPI services |
| **Tempo or Jaeger** | Add distributed tracing so a payment has one trace across merchant → nginx → aggregator → telco. | Instrument with OpenTelemetry |
| **Alertmanager** | Practise alert routing and silences. | Pair with Prometheus |
| **k6** | Generate realistic load and measure the effect of chaos. | Script the `/api/v1/payments/collect` endpoint |
| **Bruno or Insomnia** | Save and replay API requests, including bad tokens and malformed bodies. | Import `http://localhost:8080/openapi.json` |
| **Dozzle** | Browser-based live container logs. | Mount the Docker socket |
| **cAdvisor / Portainer** | See container resource use while the lab is under load. | Optional Docker add-ons |

If you add a tool, put its configuration under `observability/` or a new
top-level directory, document the port in this README, and add a `make` target.

---

## Repository layout

```
.
├── README.md                  # this file
├── AGENTS.md                  # instructions for coding agents
├── Makefile                   # common commands
├── docker-compose.yml         # the whole stack
├── db/
│   ├── 01_init.sql            # schema + seed data
│   └── queries/               # warm-up, investigations, answers
├── docs/
│   ├── architecture.md
│   ├── logs.md
│   ├── sql-workbench.md
│   ├── chaos-playbook.md
│   ├── instructor-guide.md
│   └── labs/                  # guided exercises
├── logs/                      # host-side log files (created at runtime)
├── nginx/nginx.conf
├── observability/
│   ├── datasources.yml
│   ├── dashboards.yml
│   ├── promtail.yml
│   └── dashboards/payment-lab-overview.json
├── scripts/                   # chaos, smoke, reset, sql, tail
└── services/
    ├── Dockerfile
    ├── requirements.txt
    ├── aggregator/main.py
    ├── merchant/main.py
    ├── telco/main.py
    └── shared/
```

---

## Safety

- This lab is for local training only. Do not expose it to the internet.
- All credentials, tokens, merchant names, and phone numbers are fake.
- The webhook HMAC secret is in the database and in `services/merchant/main.py`.
  That is deliberate so you can inspect it; do not copy this pattern to
  production.
- Chaos switches are global. If a colleague is using the same stack, coordinate
  before changing modes.
