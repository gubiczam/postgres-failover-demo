#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

MASTER_SERVICE="${MASTER_SERVICE:-postgres-master}"
SLAVE_SERVICE="${SLAVE_SERVICE:-postgres-slave}"

slave_recovery_status="$(
  docker compose exec -T "$SLAVE_SERVICE" \
    psql -U "$DB_USER" -d "$DB_NAME" -Atqc "SELECT pg_is_in_recovery();"
)"

if [ "$slave_recovery_status" != "t" ]; then
  echo "replication: failed - ${SLAVE_SERVICE} is not running as a standby" >&2
  exit 1
fi

replication_rows="$(
  docker compose exec -T "$MASTER_SERVICE" \
    psql -U "$DB_USER" -d "$DB_NAME" -F ' | ' -Atqc \
    "SELECT application_name, state, sync_state, write_lag, flush_lag, replay_lag
     FROM pg_stat_replication
     WHERE application_name = '${SLAVE_SERVICE}';"
)"

if [ -z "$replication_rows" ]; then
  echo "replication: failed - ${SLAVE_SERVICE} not found in pg_stat_replication on ${MASTER_SERVICE}" >&2
  exit 1
fi

replication_state="$(
  docker compose exec -T "$MASTER_SERVICE" \
    psql -U "$DB_USER" -d "$DB_NAME" -Atqc \
    "SELECT state FROM pg_stat_replication WHERE application_name = '${SLAVE_SERVICE}' LIMIT 1;"
)"

sync_state="$(
  docker compose exec -T "$MASTER_SERVICE" \
    psql -U "$DB_USER" -d "$DB_NAME" -Atqc \
    "SELECT sync_state FROM pg_stat_replication WHERE application_name = '${SLAVE_SERVICE}' LIMIT 1;"
)"

if [ "$replication_state" != "streaming" ]; then
  echo "replication: failed - expected state=streaming for ${SLAVE_SERVICE}, got ${replication_state:-<empty>}" >&2
  exit 1
fi

if [ "$sync_state" != "sync" ]; then
  echo "replication: failed - expected sync_state=sync for ${SLAVE_SERVICE}, got ${sync_state:-<empty>}" >&2
  exit 1
fi

docker compose exec -T "$MASTER_SERVICE" \
  psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" <<'SQL' >/dev/null
CREATE TABLE IF NOT EXISTS timestamp_log (
    id SERIAL PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    source_node TEXT NOT NULL
);
INSERT INTO timestamp_log (source_node) VALUES ('replication-check-primary');
SQL

if docker compose exec -T "$SLAVE_SERVICE" \
  psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" \
  -c "INSERT INTO timestamp_log (source_node) VALUES ('replication-check-standby');" >/dev/null 2>&1; then
  echo "replication: failed - standby accepted a write" >&2
  exit 1
fi

echo "standby recovery: $slave_recovery_status"
echo "pg_stat_replication:"
echo "$replication_rows"
echo "primary write test: ok"
echo "standby write test: rejected"
echo "replication: ok"
