# SQL workbench and query patterns

The lab database is MariaDB 11 with one database, `payments_lab`, and four
tables. Everything is intentionally small enough to inspect by hand.

## Connect

| Client | Host | Port | User | Password | Database |
|---|---|---|---|---|---|
| Adminer (browser) | `db` | 3306 | `root` | `rootpass` | `payments_lab` |
| CLI (`make sql`) | `db` (inside Compose) | 3306 | `root` | `rootpass` | `payments_lab` |
| DBeaver / TablePlus / DataGrip / HeidiSQL / SQL Workbench/J | `127.0.0.1` | 3306 | `root` | `rootpass` | `payments_lab` |

Adminer is at http://localhost:8081. The server field is `db`, not
`localhost`, because Adminer runs inside the Compose network.

For SQL Workbench/J, use a MariaDB/MySQL driver and:

```text
URL:      jdbc:mariadb://127.0.0.1:3306/payments_lab
User:     root
Password: rootpass
```

CLI:

```bash
make sql
make q Q="SELECT status, COUNT(*) FROM transactions GROUP BY status"
make q Q="SELECT * FROM callbacks_log ORDER BY id DESC LIMIT 5"
```

Inside `make sql`, exit with `\q`.

## Schema

### `merchants`

| Column | Type | Meaning |
|---|---|---|
| `id` | INT PK | merchant id |
| `name` | VARCHAR | display name |
| `api_token` | VARCHAR | Bearer token for `/collect` |
| `hmac_secret` | VARCHAR | secret used to sign merchant webhooks |
| `webhook_url` | VARCHAR | where the aggregator posts callbacks |
| `commission_pct` | DECIMAL | merchant commission percentage |

### `transactions`

| Column | Type | Meaning |
|---|---|---|
| `id` | INT PK | internal row id |
| `transaction_id` | VARCHAR UNIQUE | public id (`trx_...`) |
| `merchant_id` | INT | references `merchants.id` |
| `order_id` | VARCHAR | merchant’s order reference; not unique |
| `channel` | VARCHAR | `MTN_ZM`, `AIRTEL_ZM`, `MPESA_KE` |
| `amount` | DECIMAL | gross amount |
| `provider_fee` | DECIMAL NULL | fee reported by the telco |
| `currency` | VARCHAR | `ZMW` or `KES` |
| `status` | ENUM | `pending`, `success`, `failed` |
| `error_code` | VARCHAR NULL | e.g. `TELCO_504`, `DUP_ORDER` |
| `created_at` | DATETIME | UTC |

### `callbacks_log`

| Column | Type | Meaning |
|---|---|---|
| `id` | INT PK | internal row id |
| `transaction_id` | VARCHAR | references `transactions.transaction_id` |
| `attempt` | INT | 1-based attempt number |
| `http_code` | INT NULL | merchant response code; NULL means no response |
| `response_body` | VARCHAR | first 200 characters of the response |
| `sent_at` | DATETIME | UTC |

### `provider_settlements`

| Column | Type | Meaning |
|---|---|---|
| `id` | INT PK | internal row id |
| `provider_tx_id` | VARCHAR | telco’s own id |
| `external_ref` | VARCHAR | should match `transactions.transaction_id` |
| `channel` | VARCHAR | telco channel |
| `gross_amount` | DECIMAL | amount before fee |
| `fee_amount` | DECIMAL | telco fee |
| `net_amount` | DECIMAL | amount after fee |
| `provider_status` | VARCHAR | usually `SUCCESS` |
| `settled_at_eat` | DATETIME | East Africa Time (UTC+3) |

## Query patterns

### Filter and sort

```sql
SELECT transaction_id, order_id, status, amount, created_at
FROM transactions
WHERE status = 'pending'
ORDER BY created_at ASC;
```

### Join transactions to merchants

```sql
SELECT t.transaction_id, m.name AS merchant, t.channel, t.amount, t.status
FROM transactions t
JOIN merchants m ON m.id = t.merchant_id
ORDER BY t.id DESC
LIMIT 20;
```

### Aggregate by status

```sql
SELECT status, COUNT(*) AS count, SUM(amount) AS gross
FROM transactions
GROUP BY status
ORDER BY count DESC;
```

### Find rows with no match (anti-join)

```sql
SELECT t.transaction_id, t.order_id, t.status
FROM transactions t
LEFT JOIN callbacks_log c ON c.transaction_id = t.transaction_id
WHERE c.id IS NULL
ORDER BY t.id;
```

### Find duplicates

```sql
SELECT order_id, COUNT(*) AS occurrences,
       GROUP_CONCAT(transaction_id ORDER BY id) AS transactions
FROM transactions
GROUP BY order_id
HAVING COUNT(*) > 1;
```

### Latest row per group

MariaDB 11 supports window functions:

```sql
WITH ranked AS (
    SELECT c.*,
           ROW_NUMBER() OVER (PARTITION BY transaction_id ORDER BY attempt DESC) AS rn
    FROM callbacks_log c
)
SELECT transaction_id, attempt, http_code, response_body, sent_at
FROM ranked
WHERE rn = 1
ORDER BY sent_at DESC;
```

### Webhook success rate

```sql
SELECT
    COUNT(*) AS attempts,
    SUM(http_code = 200) AS ok,
    ROUND(100 * SUM(http_code = 200) / COUNT(*), 1) AS ok_pct
FROM callbacks_log;
```

### Reconcile transactions against telco settlements

```sql
SELECT
    t.transaction_id,
    t.status AS our_status,
    t.amount AS our_amount,
    s.provider_status,
    s.gross_amount AS telco_amount,
    CASE
        WHEN s.external_ref IS NULL THEN 'no settlement'
        WHEN t.amount <> s.gross_amount THEN 'amount mismatch'
        WHEN t.status <> LOWER(s.provider_status) THEN 'status mismatch'
        ELSE 'ok'
    END AS result
FROM transactions t
LEFT JOIN provider_settlements s ON s.external_ref = t.transaction_id
WHERE s.external_ref IS NULL
   OR t.amount <> s.gross_amount
   OR t.status <> LOWER(s.provider_status)
ORDER BY t.id;
```

### Timezone conversion

```sql
SELECT
    transaction_id,
    created_at AS utc_ts,
    DATE_ADD(created_at, INTERVAL 3 HOUR) AS eat_ts,
    DATE(DATE_ADD(created_at, INTERVAL 3 HOUR)) AS eat_date
FROM transactions
ORDER BY id DESC;
```

Find rows whose EAT calendar day differs from the UTC day:

```sql
SELECT transaction_id, created_at
FROM transactions
WHERE DATE(created_at) <> DATE(DATE_ADD(created_at, INTERVAL 3 HOUR));
```

### Daily merchant report

```sql
SELECT
    DATE(t.created_at) AS day,
    m.name AS merchant,
    COUNT(*) AS transactions,
    SUM(t.amount) AS gross,
    SUM(COALESCE(t.provider_fee, 0)) AS fees,
    SUM(t.amount - COALESCE(t.provider_fee, 0)) AS net
FROM transactions t
JOIN merchants m ON m.id = t.merchant_id
WHERE t.status = 'success'
GROUP BY day, m.id, m.name
ORDER BY day DESC, gross DESC;
```

### Fee vs commission

```sql
SELECT
    t.transaction_id,
    t.channel,
    t.amount,
    t.provider_fee,
    ROUND(t.amount * m.commission_pct / 100, 2) AS expected_commission,
    ROUND(t.provider_fee - (t.amount * m.commission_pct / 100), 2) AS difference
FROM transactions t
JOIN merchants m ON m.id = t.merchant_id
WHERE t.provider_fee IS NOT NULL
ORDER BY ABS(difference) DESC;
```

## Data quality checks

Run these after generating traffic:

```sql
-- 1. Pending older than 10 minutes
SELECT transaction_id, created_at
FROM transactions
WHERE status = 'pending'
  AND created_at < UTC_TIMESTAMP() - INTERVAL 10 MINUTE;

-- 2. Success without a callback
SELECT t.transaction_id
FROM transactions t
LEFT JOIN callbacks_log c ON c.transaction_id = t.transaction_id
WHERE t.status = 'success' AND c.id IS NULL;

-- 3. Pending here but settled at the telco
SELECT t.transaction_id, s.provider_status
FROM transactions t
JOIN provider_settlements s ON s.external_ref = t.transaction_id
WHERE t.status = 'pending' AND s.provider_status = 'SUCCESS';

-- 4. Duplicate order ids
SELECT order_id, COUNT(*)
FROM transactions
GROUP BY order_id
HAVING COUNT(*) > 1;

-- 5. Settlements with no transaction
SELECT s.*
FROM provider_settlements s
LEFT JOIN transactions t ON t.transaction_id = s.external_ref
WHERE t.transaction_id IS NULL;
```

## Safety

- The lab is disposable, but do not run `UPDATE` or `DELETE` while you are
  learning to read data. If you change rows, you lose the seed puzzles.
- Use `make reset` to return to the original state.
- `SELECT *` is fine for small tables. Use explicit columns once you join.
- `NULL` is not `0`. `SUM(provider_fee)` ignores NULLs; use
  `COALESCE(provider_fee, 0)` when you want zero.
- Compare timestamps only after converting to the same timezone.

## Guided exercises

- `db/queries/01_warmup.sql` — table discovery and basic aggregation
- `db/queries/02_investigations.sql` — 15 questions with hints
- `db/queries/03_answers.sql` — worked answers and expected seed results
- `docs/labs/03-sql-basics.md` — a shorter classroom path
