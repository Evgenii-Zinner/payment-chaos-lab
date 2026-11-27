#!/usr/bin/env bash
# Control the chaos switches in the payment lab.
set -euo pipefail

TELCO="${TELCO_URL:-http://localhost:8003}"
MERCHANT="${MERCHANT_URL:-http://localhost:8001}"
AGGREGATOR="${AGGREGATOR_URL:-http://localhost:8080}"

usage() {
  cat <<'EOF'
Usage: scripts/chaos.sh <command> [args]

Telco (upstream) modes
  telco normal          normal STK push + callback
  telco timeout         sleep past the aggregator/nginx timeout
  telco 503             upstream outage
  telco drop_callback   settle at telco but never call the aggregator
  telco bad_format      send a callback with the wrong JSON schema

Merchant (webhook receiver) modes
  merchant ok            return 200
  merchant 403_waf       pretend a WAF blocks the callback
  merchant 302_redirect  redirect instead of accepting the callback
  merchant 500_crash     return 500
  merchant bad_hmac      return 400

Traffic
  auto on|off            toggle the merchant auto-traffic loop (one payment / 3s)
  fire [n] [--duplicate] send n payments; --duplicate reuses one order_id
  pay <order_id>         send one payment with a specific order_id
  retry <transaction_id> re-deliver the merchant webhook for a transaction

Inspection
  status                 show current switches and service health
  settlements            download the telco settlement CSV
EOF
}

post() {
  curl -fsS -X POST "$1" >/dev/null
  echo "ok: POST $1"
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  telco)
    mode="${1:?mode required: normal|timeout|503|drop_callback|bad_format}"
    post "$TELCO/chaos/$mode"
    ;;
  merchant)
    mode="${1:?mode required: ok|403_waf|302_redirect|500_crash|bad_hmac}"
    post "$MERCHANT/chaos/$mode"
    ;;
  auto)
    state="${1:?state required: on|off}"
    post "$MERCHANT/auto/$state"
    ;;
  fire)
    count="${1:-1}"
    duplicate="false"
    if [[ "${2:-}" == "--duplicate" || "${2:-}" == "duplicate" ]]; then
      duplicate="true"
    fi
    echo "Sending $count payment(s) (duplicate=$duplicate)..."
    curl -fsS -X POST "$MERCHANT/fire/$count?duplicate=$duplicate"
    echo
    ;;
  pay)
    order_id="${1:?order_id required}"
    curl -sS -X POST "$AGGREGATOR/api/v1/payments/collect" \
      -H "Authorization: Bearer tok_zoyk_live_42" \
      -H "Content-Type: application/json" \
      -d "{\"order_id\":\"$order_id\",\"amount\":250,\"currency\":\"ZMW\",\"channel\":\"MTN_ZM\",\"phone\":\"260971112233\"}" \
      -w '\nHTTP %{http_code}\n'
    ;;
  retry)
    trx_id="${1:?transaction_id required}"
    post "$AGGREGATOR/api/v1/webhooks/retry/$trx_id"
    ;;
  status)
    echo "Telco UI:      $TELCO/"
    echo "Merchant UI:   $MERCHANT/"
    echo "Aggregator:    $AGGREGATOR/docs  (direct: http://localhost:8000/docs)"
    echo
    printf 'telco root:     '; curl -fsS -o /dev/null -w '%{http_code}\n' "$TELCO/" || true
    printf 'merchant root:  '; curl -fsS -o /dev/null -w '%{http_code}\n' "$MERCHANT/" || true
    printf 'aggregator docs:'; curl -fsS -o /dev/null -w ' %{http_code}\n' "$AGGREGATOR/docs" || true
    ;;
  settlements)
    curl -fsS "$TELCO/settlements/csv" | tee telco_settlements_eat.csv
    echo
    echo "Saved to telco_settlements_eat.csv"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage >&2
    exit 1
    ;;
esac
