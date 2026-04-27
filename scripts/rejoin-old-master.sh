#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <current-primary-service> <old-node-service>" >&2
  echo "example: $0 postgres-slave postgres-master" >&2
  echo "example: $0 postgres-master postgres-slave" >&2
  exit 1
fi

CURRENT_MASTER_SERVICE="$1"
OLD_NODE_SERVICE="$2"

wait_for_postgres "$CURRENT_MASTER_SERVICE"

if [ "$(docker compose exec -T "$CURRENT_MASTER_SERVICE" psql -U "$DB_USER" -d "$DB_NAME" -Atqc "SELECT pg_is_in_recovery();")" != "f" ]; then
  echo "rejoin: failed - ${CURRENT_MASTER_SERVICE} is not the current primary" >&2
  exit 1
fi

docker compose exec -T "$CURRENT_MASTER_SERVICE" psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${REPL_USER}') THEN
    CREATE ROLE ${REPL_USER} WITH REPLICATION LOGIN PASSWORD '${REPL_PASSWORD}';
  ELSE
    ALTER ROLE ${REPL_USER} WITH REPLICATION LOGIN PASSWORD '${REPL_PASSWORD}';
  END IF;
END
\$\$;
SQL

set_replication_hba "$CURRENT_MASTER_SERVICE"

docker compose exec -T "$CURRENT_MASTER_SERVICE" psql -U "$DB_USER" -d "$DB_NAME" -c "SELECT pg_reload_conf();" >/dev/null
clear_synchronous_standby "$CURRENT_MASTER_SERVICE"

docker compose stop "$OLD_NODE_SERVICE" >/dev/null 2>&1 || true
docker compose rm -sf "$OLD_NODE_SERVICE" >/dev/null 2>&1 || true

docker compose run --rm --no-deps --entrypoint bash \
  -e PGPASSWORD="$REPL_PASSWORD" \
  "$OLD_NODE_SERVICE" \
  -lc "
set -euo pipefail
shopt -s dotglob nullglob
rm -rf '$DATA_DIR'/*
pg_basebackup -h '$CURRENT_MASTER_SERVICE' -D '$DATA_DIR' -U '$REPL_USER' -Fp -Xs -R
"

set_standby_primary_conninfo "$OLD_NODE_SERVICE" "$CURRENT_MASTER_SERVICE" "$OLD_NODE_SERVICE"

docker compose up -d "$OLD_NODE_SERVICE" >/dev/null
wait_for_postgres "$OLD_NODE_SERVICE"

if [ "$(docker compose exec -T "$OLD_NODE_SERVICE" psql -U "$DB_USER" -d "$DB_NAME" -Atqc "SELECT pg_is_in_recovery();")" != "t" ]; then
  echo "rejoin: failed - ${OLD_NODE_SERVICE} is not running as a standby" >&2
  exit 1
fi

wait_for_streaming_replication "$CURRENT_MASTER_SERVICE" "$OLD_NODE_SERVICE"
configure_synchronous_standby "$CURRENT_MASTER_SERVICE" "$OLD_NODE_SERVICE"
wait_for_sync_replication "$CURRENT_MASTER_SERVICE" "$OLD_NODE_SERVICE"

echo "rejoin: ${OLD_NODE_SERVICE} joined as standby of ${CURRENT_MASTER_SERVICE}"
