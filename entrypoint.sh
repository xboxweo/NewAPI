#!/bin/sh
set -e

DB_PATH="${DB_PATH:-/data/one-api.db}"
WAIT_FOR_INIT="${WAIT_FOR_INIT:-true}"

echo "Starting New API..."
/new-api &

NEW_API_PID=$!

stop_all() {
  echo "Stopping..."
  kill "$NEW_API_PID" 2>/dev/null || true
  kill "$BACKUP_PID" 2>/dev/null || true
  wait
}

trap stop_all INT TERM

(
  echo "Backup watcher started"
  echo "DB_PATH=$DB_PATH"
  echo "WAIT_FOR_INIT=$WAIT_FOR_INIT"

  echo "Waiting for database file..."

  while [ ! -f "$DB_PATH" ]; do
    echo "Database file not found yet: $DB_PATH"
    sleep 10
  done

  echo "Database file found: $DB_PATH"

  if [ "$WAIT_FOR_INIT" = "true" ]; then
    echo "Waiting for New API initialization..."

    while true; do
      ROOT_COUNT="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM users WHERE role = 100 AND deleted_at IS NULL;" 2>/dev/null || echo 0)"

      if [ "$ROOT_COUNT" -gt 0 ] 2>/dev/null; then
        echo "Root user exists, system initialized"
        break
      fi

      echo "System not initialized yet, waiting..."
      sleep 15
    done
  fi

  echo "Starting backup loop..."
  /usr/local/bin/backup.sh
) &

BACKUP_PID=$!

wait "$NEW_API_PID"
