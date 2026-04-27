#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

MASTER_SERVICE="postgres-master"
SLAVE_SERVICE="postgres-slave"

wait_for_postgres "$MASTER_SERVICE"

if [ "$(docker compose exec -T "$MASTER_SERVICE" psql -U "$DB_USER" -d "$DB_NAME" -Atqc "SELECT pg_is_in_recovery();")" != "t" ]; then
  echo "failback: failed - postgres-master is not running as a standby" >&2
  exit 1
fi

fence_service_before_promotion "$SLAVE_SERVICE"

docker compose exec -T -u postgres "$MASTER_SERVICE" pg_ctl -D "$DATA_DIR" promote >/dev/null

for _ in $(seq 1 15); do
  if [ "$(docker compose exec -T "$MASTER_SERVICE" psql -U "$DB_USER" -d "$DB_NAME" -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null || true)" = "f" ]; then
    clear_synchronous_standby "$MASTER_SERVICE"
    echo "failback: postgres-master promoted to primary"
    exit 0
  fi

  sleep 1
done

echo "failback: failed - postgres-master is still in recovery mode" >&2
exit 1
