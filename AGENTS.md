# AGENTS.md

Instructions for coding agents working in the Payment Chaos Lab.

## Purpose

This repository is a local training lab for fintech payments operations and
support. It must stay runnable with one command, deterministic enough to teach
from, and safe to break on purpose. The human-facing guide is `README.md`; keep
it in sync with the code.

## Ground rules

1. **Keep it local and fake.** Never add real credentials, real phone numbers,
   real merchant data, or calls to external production services. `rootpass`,
   `tok_zoyk_live_42`, and `sec_zoyk_hmac` are intentional lab values.
2. **Keep the stack one-command.** `make up` must build and start everything.
   `make reset` must return to a known seed state.
3. **Do not remove chaos switches.** The failure modes are the product. Add new
   ones rather than replacing existing ones.
4. **Do not change ports casually.** Ports are referenced in `README.md`,
   `Makefile`, `scripts/`, `observability/dashboards/`, and the Grafana
   datasource. If you change one, update all of them.
5. **Keep timestamps honest.** `transactions.created_at` and
   `callbacks_log.sent_at` are UTC. `provider_settlements.settled_at_eat` is
   East Africa Time (UTC+3). The mismatch is a teaching point.
6. **Update docs with behavior.** Any new endpoint, mode, table, log message, or
   make target needs a line in `README.md` or the relevant `docs/` page.
7. **No production hardening claims.** This is a lab. Do not add secrets
   management, TLS, or auth complexity that makes it harder to inspect.

## Launch and verify

```bash
make up          # build + start
make smoke       # wait for services, send one payment, show logs
make ps          # container status
make status      # service health + URLs
make down        # stop, keep DB volume
make reset       # delete DB volume + logs, rebuild
```

Quick verification after a change:

```bash
docker compose config -q          # compose file is valid
bash -n scripts/*.sh              # shell syntax
python -m py_compile services/*/main.py
make up
make smoke
```

There is no unit test suite. The smoke script plus SQL checks are the test
harness. If you add Python logic, add a small assertion or a smoke check rather
than a heavy framework.

## Architecture map

| Component | Container | Host port | Code |
|---|---|---|---|
| Merchant simulator | `lab_merchant` | 8001 | `services/merchant/main.py` |
| nginx | `lab_nginx` | 8080 | `nginx/nginx.conf` |
| Aggregator | `lab_aggregator` | 8000 direct; 8080 via nginx | `services/aggregator/main.py` |
| Telco mock | `lab_telco` | 8003 | `services/telco/main.py` |
| MariaDB | `lab_db` | 3306 | `db/01_init.sql` |
| Redis | `lab_redis` | internal | chaos switches + idempotency |
| Adminer | `lab_adminer` | 8081 | image only |
| Loki | `lab_loki` | 3100 | `observability/promtail.yml` |
| Promtail | `lab_promtail` | internal | `observability/promtail.yml` |
| Grafana | `lab_grafana` | 3000 | `observability/*` |

Request flow:

```
merchant -> nginx:8080 -> aggregator:8000 -> telco:8003
telco -> nginx:8080 -> aggregator /api/v1/webhooks/telco
aggregator -> merchant /webhook (HMAC signed)
aggregator/telco -> MariaDB
aggregator/merchant/telco -> Redis (chaos + idempotency)
all log files -> promtail -> loki -> grafana
```

## Runtime contracts

### Aggregator endpoints

| Method | Path | Behavior |
|---|---|---|
| POST | `/api/v1/payments/collect` | Bearer auth, idempotency check, insert `pending`, call telco `/stkpush` |
| POST | `/api/v1/webhooks/telco` | Parse telco callback, update transaction, enqueue merchant webhook |
| POST | `/api/v1/webhooks/retry/{trx_id}` | Re-deliver merchant webhook |

Auth: `Authorization: Bearer <merchants.api_token>`.
Required body fields: `order_id`, `amount`, `currency`, `channel`, `phone`.

### Log contracts

Do not rename existing fields or `msg` values without updating `README.md`,
`docs/logs.md`, and any Loki queries.

Aggregator JSON fields: `ts`, `level`, `service`, `msg`, plus contextual keys
(`transaction_id`, `merchant_id`, `order_id`, `channel`, `attempt`,
`http_code`, `status`, `status_code`, `body`, `error`, `token_prefix`).

Merchant JSON fields: `event`, `mode`, `body`.

Telco JSON fields: `msg`, `external_ref` (and the full payload where relevant).

Nginx uses the standard combined access format and the nginx error format.

### Database schema

`db/01_init.sql` owns the schema. Key invariants:

- `transactions.transaction_id` is unique.
- `transactions.status` is `pending`, `success`, or `failed`.
- `callbacks_log` has one row per webhook attempt; `attempt` starts at 1.
- `provider_settlements.external_ref` should match
  `transactions.transaction_id` for a settled payment.
- Seed rows contain deliberate anomalies; do not “fix” the seed data without a
  teaching reason.

Run SQL:

```bash
make sql
make q Q="SELECT status, COUNT(*) FROM transactions GROUP BY status"
```

### Chaos controls

Telco: `normal`, `timeout`, `503`, `drop_callback`, `bad_format`.
Merchant webhook: `ok`, `403_waf`, `302_redirect`, `500_crash`, `bad_hmac`.
Traffic: `auto on|off`, `fire`, `pay`, `retry`.

Switches are Redis keys:

- `chaos:telco_mode`
- `chaos:merchant_wh`
- `chaos:auto_traffic`

## Common tasks

### Add a telco chaos mode

1. Add the branch in `services/telco/main.py` (`stkpush` or `finish_stk`).
2. Log a distinctive `msg` so the mode is visible in Loki.
3. Add the mode to the telco UI in the same file.
4. Add it to `scripts/chaos.sh` usage, `Makefile` help, `README.md`, and
   `docs/chaos-playbook.md`.
5. Verify with `make telco MODE=<mode>`, `make fire N=1`, then read
   `logs/aggregator/app.log`, `logs/telco/telco.log`, and the SQL tables.

### Add a merchant webhook failure mode

1. Add the branch in `services/merchant/main.py` before the HMAC check (or
   after, if the point is signature validation).
2. Add it to the merchant UI.
3. Update `scripts/chaos.sh`, `Makefile` help, `README.md`, and the playbook.
4. Confirm the aggregator records the HTTP code in `callbacks_log`.

### Add a SQL exercise

1. Add the question and hint to `db/queries/02_investigations.sql`.
2. Add a worked answer to `db/queries/03_answers.sql`.
3. If it is part of a guided lab, link it from `docs/labs/`.
4. State the expected result for a fresh seed, and note that extra traffic
   changes counts.

### Add a log file

1. Mount it in `docker-compose.yml` under the service and under `promtail`.
2. Add a scrape config in `observability/promtail.yml` with a `service` label.
3. Add the path to `README.md` and `docs/logs.md`.
4. Add a `make logs-<name>` target and `scripts/tail.sh` support if useful.
5. Add a Grafana panel or document the Explore query.

### Add a service

1. Add it to `docker-compose.yml` with a `lab_` container name.
2. Add a health check or a smoke check in `scripts/smoke.sh`.
3. Add the port to `README.md` and `Makefile` help.
4. Add log shipping if it writes files.
5. Keep `make up` and `make reset` working.

## Debugging checklist

When the lab misbehaves:

1. `docker compose ps` — are all containers up?
2. `docker compose logs --tail=100 db` — did MariaDB initialise?
3. `docker compose logs --tail=100 aggregator` — is the app crashing?
4. `ls -l logs/*/*.log` — are the host files being written?
5. `curl -s http://localhost:8080/docs -o /dev/null -w '%{http_code}'` — is
   nginx reaching the aggregator?
6. `make q Q="SELECT COUNT(*) FROM transactions"` — is the schema there?
7. `docker compose logs --tail=100 promtail loki grafana` — is log shipping
   healthy?
8. If the DB schema changed, `make reset` — init scripts do not re-run on an
   existing volume.

## Definition of done

A change is complete when:

- `docker compose config -q` passes.
- `bash -n scripts/*.sh` passes.
- `python -m py_compile services/*/main.py` passes.
- `make up && make smoke` succeeds from a clean checkout or after `make reset`.
- The new behavior is observable in at least one of: host log file, Loki, SQL
  table, Grafana dashboard.
- `README.md` and/or the relevant `docs/` page describes how a learner triggers
  and observes it.
