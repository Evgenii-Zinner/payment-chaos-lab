#!/usr/bin/env bash
# Reset the database volume and log files, then rebuild the stack.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "${1:-}" != "--yes" && "${1:-}" != "-y" ]]; then
  read -r -p "This deletes the database volume and every file in logs/. Continue? [y/N] " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || { echo "Aborted."; exit 1; }
fi

echo "Stopping containers and deleting volumes..."
docker compose down -v --remove-orphans

echo "Clearing log files..."
mkdir -p logs
find logs -type f -name '*.log' -delete 2>/dev/null || true

echo "Starting a fresh stack..."
docker compose up -d --build

echo
echo "Reset complete. Give MariaDB a few seconds to initialise, then run:"
echo "  make smoke"
