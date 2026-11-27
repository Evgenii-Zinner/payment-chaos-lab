#!/usr/bin/env bash
# Wait for the stack, send one payment, and print where to look next.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

wait_for() {
  local name="$1" url="$2" tries="${3:-60}"
  for _ in $(seq 1 "$tries"); do
    if curl -fsS -o /dev/null "$url" 2>/dev/null; then
      echo "  ok  $name"
      return 0
    fi
    sleep 1
  done
  echo "  FAIL $name ($url)" >&2
  return 1
}

echo "Waiting for services..."
wait_for "aggregator" "http://localhost:8080/docs"
wait_for "merchant" "http://localhost:8001/"
wait_for "telco" "http://localhost:8003/"
wait_for "grafana" "http://localhost:3000/api/health"
wait_for "adminer" "http://localhost:8081/"

order_id="ord_smoke_$(date +%s)"
echo
echo "Sending payment $order_id through nginx -> aggregator -> telco..."
response="$(curl -fsS -X POST http://localhost:8080/api/v1/payments/collect \
  -H 'Authorization: Bearer tok_zoyk_live_42' \
  -H 'Content-Type: application/json' \
  -d "{\"order_id\":\"$order_id\",\"amount\":250,\"currency\":\"ZMW\",\"channel\":\"MTN_ZM\",\"phone\":\"260971112233\"}")"
echo "$response"

trx_id="$(printf '%s' "$response" | sed -n 's/.*"transactionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
echo
echo "Transaction: $trx_id"
echo "Waiting 3s for the telco callback and merchant webhook..."
sleep 3

echo
echo "Aggregator log tail:"
tail -n 5 logs/aggregator/app.log 2>/dev/null || true
echo
echo "Merchant log tail:"
tail -n 3 logs/merchant/merchant.log 2>/dev/null || true
echo
echo "Next:"
echo "  make sql                    # query the transaction"
echo "  open http://localhost:3000  # Grafana -> Payment Lab Overview (admin / admin)"
echo "  open http://localhost:8081  # Adminer -> SQL workbench (server: db, user: root, pass: rootpass, db: payments_lab)"
