#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_NAME="appdb"
DB_USER="postgres"
DB_PASSWORD="postgres"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}"

cleanup_compose_state() {
  local oneoff_ids

  docker compose --profile writer stop writer >/dev/null 2>&1 || true
  docker compose --profile writer rm -sf writer >/dev/null 2>&1 || true
  docker compose stop postgres-master postgres-slave >/dev/null 2>&1 || true
  docker compose rm -sf postgres-master postgres-slave >/dev/null 2>&1 || true

  oneoff_ids="$(
    docker ps -aq \
      --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" \
      --filter "label=com.docker.compose.oneoff=True"
  )"

  if [ -n "$oneoff_ids" ]; then
    docker rm -f $oneoff_ids >/dev/null 2>&1 || true
  fi

  docker compose --profile writer down -v --remove-orphans >/dev/null
}

cleanup_on_exit() {
  local exit_code="$?"

  if [ "$exit_code" -ne 0 ]; then
    cleanup_compose_state
  fi
}

trap cleanup_on_exit EXIT

echo "[reset]"
cleanup_compose_state

echo "[start]"
docker compose up -d postgres-master postgres-slave

echo "[replication]"
./scripts/init-replication.sh

echo "[replication-check]"
./scripts/check-replication-status.sh

echo "[writer]"
docker compose --profile writer up -d --build writer

sleep 5

echo "[failover]"
./scripts/failover.sh

sleep 5

echo "[rejoin-master]"
./scripts/rejoin-old-master.sh postgres-slave postgres-master

master_recovery_status="$(
  docker compose exec -T postgres-master \
    psql -U "$DB_USER" -d "$DB_NAME" -Atqc "SELECT pg_is_in_recovery();"
)"

if [ "$master_recovery_status" != "t" ]; then
  echo "rejoin: failed - postgres-master did not rejoin as a standby" >&2
  exit 1
fi

echo "[replication-check-after-rejoin]"
MASTER_SERVICE=postgres-slave SLAVE_SERVICE=postgres-master DB_NAME="$DB_NAME" DB_USER="$DB_USER" ./scripts/check-replication-status.sh

echo "[failback]"
./scripts/failover-back.sh

sleep 5

echo "[rejoin-slave]"
./scripts/rejoin-old-master.sh postgres-master postgres-slave

slave_recovery_status="$(
  docker compose exec -T postgres-slave \
    psql -U "$DB_USER" -d "$DB_NAME" -Atqc "SELECT pg_is_in_recovery();"
)"

if [ "$slave_recovery_status" != "t" ]; then
  echo "rejoin: failed - postgres-slave did not rejoin as a standby" >&2
  exit 1
fi

echo "[replication-check-final]"
MASTER_SERVICE=postgres-master SLAVE_SERVICE=postgres-slave DB_NAME="$DB_NAME" DB_USER="$DB_USER" ./scripts/check-replication-status.sh

echo "[downtime]"
PGPASSWORD="$DB_PASSWORD" \
  psql -h localhost -p 5433 -U "$DB_USER" -d "$DB_NAME" -f scripts/downtime.sql

echo "[writer-check]"
"$SCRIPT_DIR/check-writer-switch.sh"

echo "ok"
