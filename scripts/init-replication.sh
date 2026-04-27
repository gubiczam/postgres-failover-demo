#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

MASTER_SERVICE="postgres-master"
SLAVE_SERVICE="postgres-slave"

wait_for_postgres "$MASTER_SERVICE"

docker compose exec -T "$MASTER_SERVICE" psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" <<SQL
ALTER SYSTEM SET wal_level = 'replica';
ALTER SYSTEM SET max_wal_senders = '10';
ALTER SYSTEM SET wal_keep_size = '64MB';
ALTER SYSTEM SET listen_addresses = '*';
ALTER SYSTEM SET synchronous_commit = 'on';
ALTER SYSTEM RESET synchronous_standby_names;

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

set_replication_hba "$MASTER_SERVICE"

docker compose restart "$MASTER_SERVICE" >/dev/null
wait_for_postgres "$MASTER_SERVICE"

docker compose stop "$SLAVE_SERVICE" >/dev/null 2>&1 || true
docker compose rm -sf "$SLAVE_SERVICE" >/dev/null 2>&1 || true

docker compose run --rm --no-deps --entrypoint bash \
  -e PGPASSWORD="$REPL_PASSWORD" \
  "$SLAVE_SERVICE" \
  -lc "
set -euo pipefail
shopt -s dotglob nullglob
rm -rf '$DATA_DIR'/*
pg_basebackup -h '$MASTER_SERVICE' -D '$DATA_DIR' -U '$REPL_USER' -Fp -Xs -R
"

set_standby_primary_conninfo "$SLAVE_SERVICE" "$MASTER_SERVICE" "$SLAVE_SERVICE"

docker compose up -d "$SLAVE_SERVICE" >/dev/null
wait_for_postgres "$SLAVE_SERVICE"

if [ "$(docker compose exec -T "$SLAVE_SERVICE" psql -U "$DB_USER" -d "$DB_NAME" -Atqc "SELECT pg_is_in_recovery();")" != "t" ]; then
  echo "replication init: failed - postgres-slave is not running as a standby" >&2
  exit 1
fi

wait_for_streaming_replication "$MASTER_SERVICE" "$SLAVE_SERVICE"
configure_synchronous_standby "$MASTER_SERVICE" "$SLAVE_SERVICE"
wait_for_sync_replication "$MASTER_SERVICE" "$SLAVE_SERVICE"

echo "replication init: ok"
