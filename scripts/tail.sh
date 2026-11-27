#!/usr/bin/env bash
# Follow one service log, or all of them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

service="${1:-}"
if [[ -n "$service" ]]; then
  if [[ ! -d "logs/$service" ]]; then
    echo "Unknown service: $service" >&2
    echo "Available: $(find logs -mindepth 1 -maxdepth 1 -type d -printf '%f ')" >&2
    exit 1
  fi
  exec tail -n 50 -f logs/"$service"/*.log
fi

exec tail -n 30 -f logs/*/*.log
