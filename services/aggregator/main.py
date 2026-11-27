import asyncio, hashlib, hmac, json, logging, os, uuid
from datetime import datetime, timezone
import httpx, pymysql, redis
from fastapi import FastAPI, Header, HTTPException, Request, BackgroundTasks

app = FastAPI(title="Payment Aggregator (Training Lab)")
r = redis.Redis(host=os.getenv("REDIS_HOST", "redis"), port=6379, decode_responses=True)

LOG_FILE = os.getenv("LOG_FILE", "/logs/app.log")
os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
logger = logging.getLogger("aggregator")
logger.setLevel(logging.INFO)
fh = logging.FileHandler(LOG_FILE)
logger.addHandler(fh)

def jlog(level, msg, **kw):
    entry = {"ts": datetime.now(timezone.utc).isoformat(), "level": level, "service": "aggregator", "msg": msg, **kw}
    line = json.dumps(entry)
    logger.info(line)
    print(line, flush=True)

def get_db():
    return pymysql.connect(
        host=os.getenv("DB_HOST", "db"), user="root", password=os.getenv("DB_PASS", "rootpass"),
        database=os.getenv("DB_NAME", "payments_lab"), cursorclass=pymysql.cursors.DictCursor, autocommit=True
    )

async def deliver_webhook(trx_id: str):
    db = get_db()
    with db.cursor() as cur:
        cur.execute("""
            SELECT t.*, m.webhook_url, m.hmac_secret
            FROM transactions t JOIN merchants m ON m.id = t.merchant_id
            WHERE t.transaction_id = %s
        """, (trx_id,))
        row = cur.fetchone()
    db.close()
    if not row:
        return

    db = get_db()
    with db.cursor() as cur:
        cur.execute("SELECT COALESCE(MAX(attempt), 0) AS max_attempt FROM callbacks_log WHERE transaction_id=%s", (trx_id,))
        first_attempt = int(cur.fetchone()["max_attempt"]) + 1
    db.close()

    payload = json.dumps({
        "transactionId": row["transaction_id"],
        "orderId": row["order_id"],
        "status": row["status"],
        "amount": float(row["amount"]),
        "currency": row["currency"]
    }, separators=(",", ":"))
    sig = hmac.new(row["hmac_secret"].encode(), payload.encode(), hashlib.sha256).hexdigest()

    for offset in (0, 1):
        attempt = first_attempt + offset
        code, body = 0, ""
        try:
            async with httpx.AsyncClient(timeout=3.0, follow_redirects=False) as client:
                resp = await client.post(row["webhook_url"], content=payload,
                                         headers={"Content-Type": "application/json", "X-Signature": sig})
                code, body = resp.status_code, resp.text[:200]
        except Exception as e:
            code, body = 504, str(e)[:200]

        db = get_db()
        with db.cursor() as cur:
            cur.execute("INSERT INTO callbacks_log (transaction_id, attempt, http_code, response_body, sent_at) VALUES (%s,%s,%s,%s,UTC_TIMESTAMP())",
                        (trx_id, attempt, code, body))
        db.close()
        jlog("INFO" if code == 200 else "WARN", "webhook_attempt", transaction_id=trx_id, attempt=attempt, http_code=code, body=body)
        if code == 200 and '"ok"' in body:
            break

@app.post("/api/v1/payments/collect")
async def collect(request: Request, authorization: str = Header(default="")):
    if not authorization.startswith("Bearer "):
        jlog("WARN", "missing_bearer")
        raise HTTPException(status_code=401, detail="Missing Bearer token")
    token = authorization.split(" ", 1)[1].strip()

    db = get_db()
    with db.cursor() as cur:
        cur.execute("SELECT * FROM merchants WHERE api_token=%s", (token,))
        merchant = cur.fetchone()
    db.close()
    if not merchant:
        jlog("WARN", "invalid_token", token_prefix=token[:6])
        raise HTTPException(status_code=401, detail="Invalid or expired token")

    try:
            body = await request.json()
    except Exception:
        jlog("WARN", "invalid_json_body")
        raise HTTPException(status_code=400, detail="Invalid or empty JSON body")

    for f in ("order_id", "amount", "currency", "channel", "phone"):
        if f not in body:
            raise HTTPException(status_code=400, detail=f"Missing field: {f}")

    # Idempotency check (5s Redis lock + DB check)
    idem_key = f"idem:{merchant['id']}:{body['order_id']}"
    if not r.set(idem_key, "1", nx=True, ex=10):
        jlog("WARN", "duplicate_retry_storm", merchant_id=merchant["id"], order_id=body["order_id"])
        raise HTTPException(status_code=409, detail="Duplicate order_id in progress")

    trx_id = f"trx_{uuid.uuid4().hex[:10]}"
    db = get_db()
    with db.cursor() as cur:
        cur.execute("""
            INSERT INTO transactions (transaction_id, merchant_id, order_id, channel, amount, currency, status, created_at)
            VALUES (%s,%s,%s,%s,%s,%s,'pending',UTC_TIMESTAMP())
        """, (trx_id, merchant["id"], body["order_id"], body["channel"], body["amount"], body["currency"]))
    db.close()
    jlog("INFO", "payment_initiated", transaction_id=trx_id, merchant_id=merchant["id"], channel=body["channel"], order_id=body["order_id"])

    telco_url = os.getenv("TELCO_URL", "http://telco:8003")
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.post(f"{telco_url}/stkpush", json={
                "external_ref": trx_id, "channel": body["channel"], "amount": body["amount"],
                "currency": body["currency"], "phone": body["phone"]
            })
            if resp.status_code >= 500:
                db = get_db()
                with db.cursor() as cur:
                    cur.execute("UPDATE transactions SET status='failed', error_code=%s WHERE transaction_id=%s",
                                (f"TELCO_{resp.status_code}", trx_id))
                db.close()
                jlog("ERROR", "upstream_5xx", transaction_id=trx_id, channel=body["channel"], status_code=resp.status_code)
                raise HTTPException(status_code=502, detail=f"Upstream error {resp.status_code}")
    except httpx.TimeoutException:
        db = get_db()
        with db.cursor() as cur:
            cur.execute("UPDATE transactions SET status='failed', error_code='TELCO_TIMEOUT' WHERE transaction_id=%s", (trx_id,))
        db.close()
        jlog("ERROR", "upstream_timeout", transaction_id=trx_id, channel=body["channel"])
        await asyncio.sleep(5)  # force nginx proxy_read_timeout 504!
        raise HTTPException(status_code=504, detail="Upstream timeout")

    return {"transactionId": trx_id, "status": "pending"}

@app.post("/api/v1/webhooks/telco")
async def telco_callback(request: Request, bg: BackgroundTasks):
    try:
        data = await request.json()
        trx_id = data["external_ref"]
        status = data["status"]  # success | failed
        fee = data.get("fee")
    except Exception as e:
        jlog("ERROR", "telco_callback_parse_error", error=str(e), raw=(await request.body()).decode(errors="ignore"))
        raise HTTPException(status_code=400, detail="Malformed telco callback")

    db = get_db()
    with db.cursor() as cur:
        cur.execute("UPDATE transactions SET status=%s, provider_fee=%s WHERE transaction_id=%s", (status, fee, trx_id))
    db.close()
    jlog("INFO", "telco_callback_processed", transaction_id=trx_id, status=status)
    bg.add_task(deliver_webhook, trx_id)
    return {"ok": True}

@app.post("/api/v1/webhooks/retry/{trx_id}")
async def manual_retry_webhook(trx_id: str, bg: BackgroundTasks):
    bg.add_task(deliver_webhook, trx_id)
    return {"queued": trx_id}
