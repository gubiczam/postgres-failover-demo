#!/usr/bin/env bash

DB_NAME="${DB_NAME:-appdb}"
DB_USER="${DB_USER:-postgres}"
REPL_USER="${REPL_USER:-replicator}"
REPL_PASSWORD="${REPL_PASSWORD:-replica}"
DATA_DIR="${DATA_DIR:-/var/lib/postgresql/data}"
DB_PORT="${DB_PORT:-5432}"

wait_for_postgres() {
  local service="$1"
  local attempts="${2:-60}"
  local attempt

  for attempt in $(seq 1 "$attempts"); do
    if docker compose exec -T "$service" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
      return 0
    fi

    sleep 1
  done

  echo "postgres: timed out waiting for $service" >&2
  return 1
}

service_container_id() {
  docker compose ps -q "$1"
}

is_service_running() {
  local service="$1"
  local container_id

  container_id="$(service_container_id "$service")"

  if [ -z "$container_id" ]; then
    return 1
  fi

  [ "$(docker inspect -f '{{.State.Running}}' "$container_id")" = "true" ]
}

wait_for_service_stopped() {
  local service="$1"
  local attempts="${2:-20}"
  local attempt

  for attempt in $(seq 1 "$attempts"); do
    if ! is_service_running "$service"; then
      return 0
    fi

    sleep 1
  done

  echo "fencing: timed out waiting for $service to stop" >&2
  return 1
}

ensure_service_not_writable_primary() {
  local service="$1"
  local recovery_state

  if ! is_service_running "$service"; then
    return 0
  fi

  if ! recovery_state="$(
    docker compose exec -T "$service" \
      psql -U "$DB_USER" -d "$DB_NAME" -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null
  )"; then
    return 0
  fi

  if [ "$recovery_state" = "f" ]; then
    echo "fencing: $service is still reachable as a writable primary" >&2
    return 1
  fi

  return 0
}

fence_service_before_promotion() {
  local service="$1"

  docker compose stop "$service" >/dev/null
  wait_for_service_stopped "$service"
  ensure_service_not_writable_primary "$service"
}

set_replication_hba() {
  local service="$1"
  local hba_line="host replication ${REPL_USER} 0.0.0.0/0 md5"

  docker compose exec -T "$service" bash -lc "
set -euo pipefail
pg_hba='${DATA_DIR}/pg_hba.conf'
sed -i '/^host[[:space:]]\\+replication[[:space:]]\\+/d' \"\$pg_hba\"
printf '%s\n' '$hba_line' >> \"\$pg_hba\"
"
}

set_standby_primary_conninfo() {
  local standby_service="$1"
  local upstream_service="$2"
  local application_name="$3"

  docker compose run --rm --no-deps --entrypoint bash \
    -e PGPASSWORD="$REPL_PASSWORD" \
    "$standby_service" \
    -lc "
set -euo pipefail
conf='${DATA_DIR}/postgresql.auto.conf'
sed -i \"/^primary_conninfo = /d\" \"\$conf\"
printf \"%s\n\" \"primary_conninfo = 'host=${upstream_service} port=${DB_PORT} user=${REPL_USER} password=${REPL_PASSWORD} application_name=${application_name}'\" >> \"\$conf\"
"
}

clear_synchronous_standby() {
  local service="$1"

  docker compose exec -T "$service" psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" <<'SQL' >/dev/null
ALTER SYSTEM RESET synchronous_standby_names;
ALTER SYSTEM SET synchronous_commit = 'on';
SELECT pg_reload_conf();
SQL
}

configure_synchronous_standby() {
  local master_service="$1"
  local standby_name="$2"
  local quoted_standby_name="${standby_name//\"/\"\"}"

  docker compose exec -T "$master_service" psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" <<SQL >/dev/null
ALTER SYSTEM SET synchronous_commit = 'on';
ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 ("${quoted_standby_name}")';
SELECT pg_reload_conf();
SQL
}

wait_for_sync_replication() {
  local master_service="$1"
  local standby_name="$2"
  local attempts="${3:-30}"
  local attempt
  local sync_state

  for attempt in $(seq 1 "$attempts"); do
    sync_state="$(
      docker compose exec -T "$master_service" \
        psql -U "$DB_USER" -d "$DB_NAME" -Atqc \
        "SELECT sync_state FROM pg_stat_replication WHERE application_name = '${standby_name}' AND state = 'streaming' LIMIT 1;"
    )"

    if [ "$sync_state" = "sync" ]; then
      return 0
    fi

    sleep 1
  done

  echo "replication: timed out waiting for synchronous replication from ${standby_name} on ${master_service}" >&2
  return 1
}

wait_for_streaming_replication() {
  local master_service="$1"
  local standby_name="$2"
  local attempts="${3:-30}"
  local attempt
  local replication_state

  for attempt in $(seq 1 "$attempts"); do
    replication_state="$(
      docker compose exec -T "$master_service" \
        psql -U "$DB_USER" -d "$DB_NAME" -Atqc \
        "SELECT state FROM pg_stat_replication WHERE application_name = '${standby_name}' LIMIT 1;"
    )"

    if [ "$replication_state" = "streaming" ]; then
      return 0
    fi

    sleep 1
  done

  echo "replication: timed out waiting for streaming replication from ${standby_name} on ${master_service}" >&2
  return 1
}
