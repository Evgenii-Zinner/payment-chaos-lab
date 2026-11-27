# Instructor guide

This lab works for a 60–120 minute session with 1–20 learners. Each learner can
run their own stack, or the group can share one stack and take turns driving
the chaos switches.

## Audience

- Support engineers learning payments troubleshooting
- Backend engineers new to fintech or webhooks
- QA engineers practising failure injection
- Data analysts learning to reconcile operational data

Assumed knowledge: basic HTTP, basic SQL (`SELECT`, `WHERE`, `JOIN`,
`GROUP BY`). No Docker knowledge is required beyond `make up` and `make reset`.

## Learning outcomes

By the end, a learner can:

1. Explain the merchant → aggregator → telco flow and where webhooks fit.
2. Find the correct log file for a service and filter JSON lines.
3. Write SQL to find pending, failed, duplicated, and unreconciled payments.
4. Distinguish a payment failure from a notification failure.
5. Explain why UTC and UTC+3 data disagree and how to reconcile them.
6. Use Grafana/Loki to search logs and Grafana/MySQL to query data.

## Before the session

On each machine:

```bash
git clone <repo> payment-chaos-lab   # or copy the directory
cd payment-chaos-lab
make up
make smoke
```

Checklist:

- [ ] Docker is running.
- [ ] Ports `3000`, `3306`, `8000`, `8001`, `8003`, `8080`, `8081`, `3100` are free.
- [ ] `make smoke` prints a transaction id.
- [ ] http://localhost:3000 loads Grafana (`admin` / `admin`).
- [ ] http://localhost:8081 loads Adminer.
- [ ] `make sql` opens a MariaDB prompt.
- [ ] The **Payment Lab Overview** dashboard shows data.

If learners share a host, warn them that chaos switches are global.

## Suggested 90-minute agenda

| Time | Topic | Activity |
|---|---|---|
| 0–10 | Orientation | Tour the four UIs; draw the request flow on a whiteboard |
| 10–20 | First payment | `make smoke`, then find the transaction in SQL and Loki |
| 20–35 | Reading logs | `jq` filters, nginx status codes, Grafana Explore |
| 35–50 | SQL basics | Warm-up queries; find the seed anomalies |
| 50–65 | Stuck payments | `drop_callback` and `bad_format` scenarios |
| 65–80 | Webhook failures | `403_waf`, `500_crash`, manual retry |
| 80–90 | Debrief | Reconciliation, idempotency, what to monitor |

## Suggested 120-minute agenda

Add:

- 15 minutes on timezone reconciliation and the settlement CSV.
- 15 minutes on duplicate retry storms and idempotency.
- 10 minutes on designing alerts and runbooks.

## Facilitation notes

### Start with the happy path

Do not open with chaos. Send one payment, then ask learners to find:

- the merchant request in nginx,
- the `payment_initiated` line in the aggregator,
- the `callbacks_log` row,
- the settlement row.

Only after they can trace a success should you introduce failure.

### Make them predict before they run

For each scenario, ask:

> “If the telco drops the callback, which table will be wrong, and what will
> the merchant see?”

Then run it and compare. Prediction is where the learning happens.

### Separate the three truths

Repeatedly return to these questions:

1. What does our database think?
2. What does the telco think?
3. What did the merchant receive?

Most incidents are a disagreement between those three.

### Use the seed data

The seed rows are designed as mini-incidents. Ask learners to find them without
running chaos first:

```sql
SELECT transaction_id, order_id, status, provider_fee, error_code
FROM transactions
WHERE transaction_id LIKE 'trx_seed_%';
```

Then ask which ones are suspicious and why.

## Common learner mistakes

| Mistake | Correction |
|---|---|
| Looking at `docker compose logs` and expecting file logs | Use `make tail` or `logs/*.log` |
| Comparing `created_at` with `settled_at_eat` directly | Convert UTC to UTC+3 first |
| Treating a webhook 500 as a failed payment | Check `transactions.status`; the payment may be successful |
| Using `localhost` as the Adminer server | Use `db` inside Compose |
| Forgetting that init SQL runs only on an empty volume | Use `make reset` after schema changes |
| Leaving auto-traffic on during analysis | `make auto STATE=off` |
| Assuming a timeout means no payment | The telco may settle later; check settlements |

## Assessment prompts

Ask learners to answer without running the lab first, then verify:

1. A merchant got a 504. The transaction is `failed` with `TELCO_TIMEOUT`.
   The settlement table has a `SUCCESS` row. What happened, and what should
   support tell the merchant?
2. A transaction is `success`, but `callbacks_log` has two 500s. Is the customer
   paid? Is the merchant notified?
3. Two rows share `ord_dup_1`. One is `success`, one is `failed` with
   `DUP_ORDER`. Which one is the real payment?
4. A settlement is dated 25 November, but the transaction is dated 24 November.
   Is that a bug?
5. Write a query that returns every transaction needing manual review. Define
   “needs review” in one sentence first.

## Extension projects

- Add a reconciliation job that writes mismatches to a new table.
- Add a dead-letter queue for callbacks that exhaust retries.
- Add Prometheus metrics and a Grafana alert for pending > 10 minutes.
- Add a refund endpoint and a refund webhook.
- Add a second telco provider and route by channel.
- Add HMAC replay protection with a timestamp and nonce.
- Add a load test with k6 and measure the effect of `timeout`.

## Cleanup

At the end:

```bash
make auto STATE=off
make down
```

Use `make reset` before the next session to remove data from the previous group.
