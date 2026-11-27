# Lab 2 — Read the logs

**Goal:** become comfortable with the log files, JSON filtering, nginx status
codes, and Grafana/Loki.

**Time:** 20 minutes.

## Setup

```bash
make auto STATE=off
make fire N=5
```

Wait 2 seconds for callbacks.

## Part A — file basics

1. Which log files exist?

   ```bash
   find logs -type f -name '*.log' -printf '%p %s bytes\n'
   ```

2. How many lines does each have?

   ```bash
   wc -l logs/*/*.log
   ```

3. Follow all logs while you send one payment:

   ```bash
   make tail
   ```

   In another terminal:

   ```bash
   make fire N=1
   ```

## Part B — jq

1. Pretty-print the last aggregator event:

   ```bash
   tail -n 1 logs/aggregator/app.log | jq .
   ```

2. Show only warnings and errors:

   ```bash
   jq -c 'select(.level == "ERROR" or .level == "WARN")' logs/aggregator/app.log | tail -20
   ```

3. Count events by `msg`:

   ```bash
   jq -r '.msg // .event' logs/aggregator/app.log | sort | uniq -c | sort -nr
   ```

4. Show every webhook attempt as a table:

   ```bash
   jq -r 'select(.msg == "webhook_attempt") | [.ts, .transaction_id, .attempt, .http_code] | @tsv' \
     logs/aggregator/app.log | tail -20
   ```

5. Count webhook HTTP codes:

   ```bash
   jq -r 'select(.msg == "webhook_attempt") | .http_code' logs/aggregator/app.log \
     | sort | uniq -c | sort -nr
   ```

6. Read the merchant log:

   ```bash
   jq -c 'select(.event == "webhook_received")' logs/merchant/merchant.log | tail -5
   ```

## Part C — nginx

1. Count status codes:

   ```bash
   awk '{print $9}' logs/nginx/access.log | sort | uniq -c | sort -nr
   ```

2. Find 5xx responses:

   ```bash
   awk '$9 ~ /^5/ {print}' logs/nginx/access.log | tail -20
   ```

3. Find upstream timeouts:

   ```bash
   grep -i 'timed out' logs/nginx/error.log | tail -10
   ```

## Part D — Loki and Grafana

1. Open http://localhost:3000 → **Explore** → **Loki**.
2. Run:

   ```logql
   {service="aggregator"}
   ```

3. Filter to payment starts:

   ```logql
   {service="aggregator"} |= "payment_initiated"
   ```

4. Parse JSON and filter by field:

   ```logql
   {service="aggregator"} | json | msg="webhook_attempt"
   ```

5. Show all warnings/errors across services:

   ```logql
   {service=~".+"} |~ "ERROR|WARN|CHAOS"
   ```

6. Show nginx 5xx:

   ```logql
   {service="nginx"} |~ " 5[0-9][0-9] "
   ```

## Questions

1. Which log file would you check first for an nginx 504?
2. Which log line tells you the merchant rejected a webhook?
3. Why can’t you `jq` the nginx access log?
4. What is the difference between `make logs` and `make tail`?
5. Which `msg` values indicate a failure on the platform side, not the merchant
   side?

## Challenge

Write a one-liner that prints only the `transaction_id` values whose webhook
attempt returned a non-200 code.

<details>
<summary>Answer</summary>

```bash
jq -r 'select(.msg == "webhook_attempt" and .http_code != 200) | .transaction_id' \
  logs/aggregator/app.log | sort -u
```

</details>
