#!/usr/bin/env bash
# Open a MariaDB shell inside the db container, or run one query.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ $# -eq 0 ]]; then
  exec docker compose exec db mariadb -uroot -prootpass payments_lab
fi

exec docker compose exec -T db mariadb -uroot -prootpass payments_lab -e "$*"
