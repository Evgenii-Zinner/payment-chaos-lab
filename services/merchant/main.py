import asyncio, hashlib, hmac, json, logging, os, random
import httpx, redis
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse

app = FastAPI(title="Merchant Simulator (Training Lab)")
r = redis.Redis(host=os.getenv("REDIS_HOST", "redis"), port=6379, decode_responses=True)
AGG = os.getenv("AGGREGATOR_URL", "http://nginx:80")
TOKEN = "tok_zoyk_live_42"
SECRET = "sec_zoyk_hmac"

LOG_FILE = os.getenv("LOG_FILE", "/logs/merchant.log")
os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
fh = logging.FileHandler(LOG_FILE)
logger = logging.getLogger("merchant"); logger.setLevel(logging.INFO); logger.addHandler(fh)

def wh_mode():
    return r.get("chaos:merchant_wh") or "ok"

def auto_mode():
    return r.get("chaos:auto_traffic") or "off"

async def send_one_payment(client: httpx.AsyncClient, oid: str):
    channel = random.choice(["MTN_ZM", "AIRTEL_ZM", "MPESA_KE"])
    currency = "KES" if channel == "MPESA_KE" else "ZMW"
    return await client.post(
        f"{AGG}/api/v1/payments/collect",
        headers={"Authorization": f"Bearer {TOKEN}"},
        json={
            "order_id": oid,
            "amount": random.choice([100, 250, 500, 750]),
            "currency": currency,
            "channel": channel,
            "phone": "260971112233",
        },
    )

@app.on_event("startup")
async def start_auto_traffic():
    async def loop():
        async with httpx.AsyncClient(timeout=8.0) as client:
            while True:
                await asyncio.sleep(3)
                try:
                    if auto_mode() == "on":
                        await send_one_payment(client, f"ord_auto_{random.randint(100000,999999)}")
                except Exception as e:
                    logger.info(json.dumps({"event": "auto_traffic_error", "error": str(e)}))
    asyncio.create_task(loop())

@app.post("/webhook")
async def receive_webhook(request: Request, x_signature: str = Header(default="")):
    raw = await request.body()
    mode = wh_mode()
    logger.info(json.dumps({"event": "webhook_received", "mode": mode, "body": raw.decode()}))

    if mode == "403_waf":
        raise HTTPException(status_code=403, detail="Cloudflare WAF: IP not whitelisted")
    if mode == "302_redirect":
        return RedirectResponse(url="https://example.com/webhook", status_code=302)
    if mode == "500_crash":
        raise HTTPException(status_code=500, detail="Merchant DB Deadlock")
    if mode == "bad_hmac":
        raise HTTPException(status_code=400, detail="Invalid HMAC signature")

    expected = hmac.new(SECRET.encode(), raw, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, x_signature):
        raise HTTPException(status_code=400, detail="Signature mismatch")
    return {"result": "ok"}

@app.post("/chaos/{mode}")
def set_wh(mode: str):
    r.set("chaos:merchant_wh", mode)
    return {"merchant_wh": mode}

@app.post("/auto/{state}")
def set_auto(state: str):
    r.set("chaos:auto_traffic", state)
    return {"auto_traffic": state}

@app.post("/fire/{count}")
async def fire_traffic(count: int, duplicate: bool = False):
    results = []
    fixed_order = f"ord_storm_{random.randint(100,999)}"
    async with httpx.AsyncClient(timeout=8.0) as client:
        for _ in range(count):
            oid = fixed_order if duplicate else f"ord_{random.randint(10000,99999)}"
            resp = await send_one_payment(client, oid)
            results.append({"code": resp.status_code, "body": resp.text})
    return {"sent": count, "results": results}

@app.get("/", response_class=HTMLResponse)
def ui():
    m = wh_mode()
    a = auto_mode()
    return f"""
    <h2>Merchant Simulator (Webhook: <b>{m}</b> | Auto-Traffic: <b>{a}</b>)</h2>
    <p>Auto-Traffic (1 payment every 3s):
      <button onclick="fetch('/auto/on',{{method:'POST'}}).then(()=>location.reload())">Turn ON</button>
      <button onclick="fetch('/auto/off',{{method:'POST'}}).then(()=>location.reload())">Turn OFF</button>
    </p>
    <p>Manual Burst:
      <button onclick="fetch('/fire/1',{{method:'POST'}}).then(r=>r.json()).then(d=>alert(JSON.stringify(d)))">Send 1 Payment</button>
      <button onclick="fetch('/fire/10',{{method:'POST'}}).then(r=>r.json()).then(d=>alert('Sent 10'))">Send 10 Payments</button>
      <button onclick="fetch('/fire/3?duplicate=true',{{method:'POST'}}).then(r=>r.json()).then(d=>alert(JSON.stringify(d)))">Trigger Retry Storm (3x same order_id)</button>
    </p>
    <p>Break Merchant Webhook:
      <button onclick="fetch('/chaos/ok',{{method:'POST'}}).then(()=>location.reload())">ok (200)</button>
      <button onclick="fetch('/chaos/403_waf',{{method:'POST'}}).then(()=>location.reload())">403 Cloudflare</button>
      <button onclick="fetch('/chaos/302_redirect',{{method:'POST'}}).then(()=>location.reload())">302 Redirect</button>
      <button onclick="fetch('/chaos/500_crash',{{method:'POST'}}).then(()=>location.reload())">500 Crash</button>
      <button onclick="fetch('/chaos/bad_hmac',{{method:'POST'}}).then(()=>location.reload())">400 Bad HMAC</button>
    </p>
    """
