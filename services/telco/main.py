import csv, io, json, logging, os, uuid
from datetime import datetime, timedelta, timezone
import httpx, pymysql, redis
from fastapi import FastAPI, BackgroundTasks, HTTPException
from fastapi.responses import HTMLResponse, StreamingResponse

app = FastAPI(title="Telco Mock (Training Lab)")
r = redis.Redis(host=os.getenv("REDIS_HOST", "redis"), port=6379, decode_responses=True)

LOG_FILE = os.getenv("LOG_FILE", "/logs/telco.log")
os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
fh = logging.FileHandler(LOG_FILE)
logger = logging.getLogger("telco"); logger.setLevel(logging.INFO); logger.addHandler(fh)

def get_db():
    return pymysql.connect(host=os.getenv("DB_HOST","db"), user="root", password=os.getenv("DB_PASS","rootpass"),
                           database=os.getenv("DB_NAME","payments_lab"), cursorclass=pymysql.cursors.DictCursor, autocommit=True)

def get_mode():
    return r.get("chaos:telco_mode") or "normal"

async def finish_stk(payload: dict):
    import asyncio
    await asyncio.sleep(1)
    mode = get_mode()
    fee = round(float(payload["amount"]) * 0.0175, 2)
    net = round(float(payload["amount"]) - fee, 2)
    eat_now = (datetime.now(timezone.utc) + timedelta(hours=3)).strftime("%Y-%m-%d %H:%M:%S")
    db = get_db()
    with db.cursor() as cur:
        cur.execute("""
            INSERT INTO provider_settlements (provider_tx_id, external_ref, channel, gross_amount, fee_amount, net_amount, provider_status, settled_at_eat)
            VALUES (%s,%s,%s,%s,%s,%s,'SUCCESS',%s)
        """, (f"prv_{uuid.uuid4().hex[:8]}", payload["external_ref"], payload["channel"], payload["amount"], fee, net, eat_now))
    db.close()

    if mode == "drop_callback":
        logger.info(json.dumps({"msg": "CHAOS_DROPPED_CALLBACK", "external_ref": payload["external_ref"]}))
        return

    cb_body = {"external_ref": payload["external_ref"], "status": "success", "fee": fee}
    if mode == "bad_format":
        cb_body = {"broken_schema_v2": True, "ref": payload["external_ref"]}

    async with httpx.AsyncClient(timeout=5.0) as client:
        await client.post("http://nginx:80/api/v1/webhooks/telco", json=cb_body)

@app.post("/stkpush")
async def stkpush(payload: dict, bg: BackgroundTasks):
    import asyncio
    mode = get_mode()
    if mode == "timeout":
        await asyncio.sleep(6)
    if mode == "503":
        raise HTTPException(status_code=503, detail="Telco Maintenance / Overload")
    bg.add_task(finish_stk, payload)
    return {"accepted": True}

@app.post("/chaos/{mode}")
def set_mode(mode: str):
    r.set("chaos:telco_mode", mode)
    return {"telco_mode": mode}

@app.get("/settlements/csv")
def export_csv():
    db = get_db()
    with db.cursor() as cur:
        cur.execute("SELECT * FROM provider_settlements ORDER BY id DESC")
        rows = cur.fetchall()
    db.close()
    buf = io.StringIO()
    if rows:
        w = csv.DictWriter(buf, fieldnames=rows[0].keys())
        w.writeheader(); w.writerows(rows)
    return StreamingResponse(iter([buf.getvalue()]), media_type="text/csv",
                             headers={"Content-Disposition": "attachment; filename=telco_settlements_eat.csv"})

@app.get("/", response_class=HTMLResponse)
def ui():
    m = get_mode()
    return f"""
    <h2>Telco Mock & Chaos Panel (Current mode: <b>{m}</b>)</h2>
    <p>Modes (POST /chaos/&lt;mode&gt;):
      <button onclick="fetch('/chaos/normal',{{method:'POST'}}).then(()=>location.reload())">normal</button>
      <button onclick="fetch('/chaos/timeout',{{method:'POST'}}).then(()=>location.reload())">timeout (504)</button>
      <button onclick="fetch('/chaos/503',{{method:'POST'}}).then(()=>location.reload())">503 outage</button>
      <button onclick="fetch('/chaos/drop_callback',{{method:'POST'}}).then(()=>location.reload())">drop_callback (stuck Pending!)</button>
      <button onclick="fetch('/chaos/bad_format',{{method:'POST'}}).then(()=>location.reload())">bad_format (wrong JSON schema)</button>
    </p>
    <p><a href="/settlements/csv">Download Telco Settlement CSV (UTC+3)</a></p>
    """
