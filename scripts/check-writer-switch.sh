#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

DB_SERVICE="${DB_SERVICE:-postgres-master}"

writer_logs="$(docker compose logs --tail=200 writer 2>&1 || true)"
writer_log_status=0
data_status=0

has_master_log=0
has_slave_log=0

if echo "$writer_logs" | grep -Fq "connected to writable primary: postgres-master"; then
  has_master_log=1
fi

if echo "$writer_logs" | grep -Fq "connected to writable primary: postgres-slave"; then
  has_slave_log=1
fi

if [ "$has_master_log" -eq 1 ] && [ "$has_slave_log" -eq 1 ]; then
  writer_log_status=1
fi

master_rows="$(
  docker compose exec -T "$DB_SERVICE" \
    psql -U "$DB_USER" -d "$DB_NAME" -Atqc \
    "SELECT count(*) FROM timestamp_log WHERE source_node = 'postgres-master';"
)"

slave_rows="$(
  docker compose exec -T "$DB_SERVICE" \
    psql -U "$DB_USER" -d "$DB_NAME" -Atqc \
    "SELECT count(*) FROM timestamp_log WHERE source_node = 'postgres-slave';"
)"

master_to_slave_transitions="$(
  docker compose exec -T "$DB_SERVICE" \
    psql -U "$DB_USER" -d "$DB_NAME" -Atqc \
    "WITH ordered AS (
       SELECT source_node, LAG(source_node) OVER (ORDER BY created_at, id) AS previous_source_node
       FROM timestamp_log
       WHERE source_node IN ('postgres-master', 'postgres-slave')
     )
     SELECT count(*)
     FROM ordered
     WHERE previous_source_node = 'postgres-master' AND source_node = 'postgres-slave';"
)"

slave_to_master_transitions="$(
  docker compose exec -T "$DB_SERVICE" \
    psql -U "$DB_USER" -d "$DB_NAME" -Atqc \
    "WITH ordered AS (
       SELECT source_node, LAG(source_node) OVER (ORDER BY created_at, id) AS previous_source_node
       FROM timestamp_log
       WHERE source_node IN ('postgres-master', 'postgres-slave')
     )
     SELECT count(*)
     FROM ordered
     WHERE previous_source_node = 'postgres-slave' AND source_node = 'postgres-master';"
)"

if [ "${master_rows:-0}" -gt 0 ] && [ "${slave_rows:-0}" -gt 0 ] \
  && [ "${master_to_slave_transitions:-0}" -gt 0 ] && [ "${slave_to_master_transitions:-0}" -gt 0 ]; then
  data_status=1
fi

if [ "$writer_log_status" -eq 1 ] && [ "$data_status" -eq 1 ]; then
  echo "writer switch: ok"
  echo "writer rows: postgres-master=$master_rows postgres-slave=$slave_rows"
  echo "writer transitions: primary->standby=$master_to_slave_transitions standby->primary=$slave_to_master_transitions"
  exit 0
fi

if [ "$writer_log_status" -ne 1 ]; then
  echo "writer switch: failed - writer did not connect to both primaries" >&2
fi

if [ "$data_status" -ne 1 ]; then
  echo "writer switch: failed - missing timestamp rows or primary transition evidence" >&2
  echo "writer rows: postgres-master=${master_rows:-0} postgres-slave=${slave_rows:-0}" >&2
  echo "writer transitions: primary->standby=${master_to_slave_transitions:-0} standby->primary=${slave_to_master_transitions:-0}" >&2
fi

exit 1
