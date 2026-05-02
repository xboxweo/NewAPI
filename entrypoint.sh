#!/bin/sh
set -u

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

require_env() {
  name="$1"
  eval value="\${$name:-}"
  if [ -z "$value" ]; then
    log "Missing required env: $name"
    exit 1
  fi
}

require_env R2_ENDPOINT
require_env R2_BUCKET
require_env AWS_ACCESS_KEY_ID
require_env AWS_SECRET_ACCESS_KEY

DB_PATH="${DB_PATH:-/data/one-api.db}"
R2_PREFIX="${R2_PREFIX:-newapi}"
BACKUP_INTERVAL_SECONDS="${BACKUP_INTERVAL_SECONDS:-21600}"
WAIT_FOR_INIT="${WAIT_FOR_INIT:-true}"
NEW_API_BIN="${NEW_API_BIN:-/new-api}"

R2_PREFIX="$(echo "$R2_PREFIX" | sed 's#^/##; s#/$##')"

if [ -n "$R2_PREFIX" ]; then
  S3_PREFIX="$R2_PREFIX/"
else
  S3_PREFIX=""
fi

TMP_DIR="/tmp/newapi-backup"
mkdir -p "$TMP_DIR"

APP_PID=""
BACKUP_PID=""

log "Entrypoint started"
log "DB_PATH=$DB_PATH"
log "R2_ENDPOINT=$R2_ENDPOINT"
log "R2_BUCKET=$R2_BUCKET"
log "R2_PREFIX=$R2_PREFIX"
log "BACKUP_INTERVAL_SECONDS=$BACKUP_INTERVAL_SECONDS"
log "WAIT_FOR_INIT=$WAIT_FOR_INIT"

latest_backup_key() {
  aws \
    --endpoint-url "$R2_ENDPOINT" \
    s3api list-objects-v2 \
    --bucket "$R2_BUCKET" \
    --prefix "$S3_PREFIX" \
    --query 'Contents[].[LastModified,Key]' \
    --output text 2>/dev/null \
    | grep '\.db\.gz$' \
    | sort \
    | tail -n 1 \
    | awk '{print $2}'
}

restore_latest_backup() {
  log "Checking latest backup from R2..."

  LATEST_KEY="$(latest_backup_key || true)"

  if [ -z "$LATEST_KEY" ] || [ "$LATEST_KEY" = "None" ]; then
    log "No remote backup found"
    return 1
  fi

  log "Latest remote backup: $LATEST_KEY"

  RESTORE_GZ="$TMP_DIR/restore.db.gz"
  RESTORE_DB="$TMP_DIR/restore.db"

  rm -f "$RESTORE_GZ" "$RESTORE_DB"

  aws \
    --endpoint-url "$R2_ENDPOINT" \
    s3 cp "s3://$R2_BUCKET/$LATEST_KEY" "$RESTORE_GZ" || {
      log "Download latest backup failed"
      return 1
    }

  gzip -dc "$RESTORE_GZ" > "$RESTORE_DB" || {
    log "Unzip backup failed"
    return 1
  }

  if ! sqlite3 "$RESTORE_DB" "PRAGMA integrity_check;" | grep -qx "ok"; then
    log "SQLite integrity check failed, refuse to restore"
    return 1
  fi

  DB_DIR="$(dirname "$DB_PATH")"
  mkdir -p "$DB_DIR"

  if [ -f "$DB_PATH" ]; then
    LOCAL_BAK="$DB_PATH.before-restore-$(date +%Y%m%d-%H%M%S)"
    log "Local database exists, saving copy to $LOCAL_BAK"
    cp "$DB_PATH" "$LOCAL_BAK" || return 1
  fi

  cp "$RESTORE_DB" "$DB_PATH" || {
    log "Restore database failed"
    return 1
  }

  log "Restore finished: $DB_PATH"
  return 0
}

backup_once() {
  TYPE="${1:-scheduled}"

  log "Starting $TYPE backup..."

  if [ ! -f "$DB_PATH" ]; then
    log "Database file not found: $DB_PATH"
    return 1
  fi

  TIME="$(date +%Y%m%d-%H%M%S)"
  TMP_DB="$TMP_DIR/one-api-$TIME.db"
  TMP_GZ="$TMP_DB.gz"
  OBJECT_KEY="${S3_PREFIX}one-api-$TIME.db.gz"

  rm -f "$TMP_DB" "$TMP_GZ"

  sqlite3 "$DB_PATH" ".backup '$TMP_DB'" || {
    log "SQLite backup failed"
    return 1
  }

  gzip -f "$TMP_DB" || {
    log "gzip failed"
    return 1
  }

  aws \
    --endpoint-url "$R2_ENDPOINT" \
    s3 cp "$TMP_GZ" "s3://$R2_BUCKET/$OBJECT_KEY" || {
      log "Upload to R2 failed"
      rm -f "$TMP_GZ"
      return 1
    }

  rm -f "$TMP_GZ"

  log "Backup uploaded: s3://$R2_BUCKET/$OBJECT_KEY"
  log "$TYPE backup finished"
  return 0
}

wait_for_db() {
  log "Waiting for database file: $DB_PATH"

  while [ ! -f "$DB_PATH" ]; do
    log "Database file not found yet"
    sleep 5
  done

  log "Database file found"
}

wait_for_init() {
  if [ "$WAIT_FOR_INIT" != "true" ]; then
    log "WAIT_FOR_INIT is false, skip initialization check"
    return 0
  fi

  log "Waiting for New API initialization..."

  while true; do
    ROOT_COUNT="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM users WHERE role = 100 AND deleted_at IS NULL;" 2>/dev/null || echo 0)"

    if [ "$ROOT_COUNT" -gt 0 ] 2>/dev/null; then
      log "Root user exists, system initialized"
      return 0
    fi

    log "System not initialized yet, waiting..."
    sleep 10
  done
}

backup_loop() {
  while true; do
    log "Sleeping ${BACKUP_INTERVAL_SECONDS}s before next scheduled backup..."
    sleep "$BACKUP_INTERVAL_SECONDS"

    if backup_once "scheduled"; then
      log "Scheduled backup success"
    else
      log "Scheduled backup failed"
    fi
  done
}

stop_all() {
  log "Stopping..."

  if [ -n "$BACKUP_PID" ]; then
    kill "$BACKUP_PID" 2>/dev/null || true
  fi

  if [ -n "$APP_PID" ]; then
    kill "$APP_PID" 2>/dev/null || true
  fi

  exit 0
}

trap stop_all INT TERM

REMOTE_BACKUP_EXISTS="false"

if restore_latest_backup; then
  REMOTE_BACKUP_EXISTS="true"
  log "Remote backup restored successfully"
else
  REMOTE_BACKUP_EXISTS="false"
  log "No remote backup restored"
fi

log "Starting New API..."
"$NEW_API_BIN" &

APP_PID="$!"

if [ "$REMOTE_BACKUP_EXISTS" = "false" ]; then
  log "Remote backup does not exist, will create initial backup after initialization"

  wait_for_db
  wait_for_init

  if backup_once "initial"; then
    log "Initial backup submitted successfully"
  else
    log "Initial backup failed"
  fi
else
  log "Remote backup exists, skip initial backup"
fi

backup_loop &

BACKUP_PID="$!"

wait "$APP_PID"
EXIT_CODE="$?"

log "New API exited with code $EXIT_CODE"

if [ -n "$BACKUP_PID" ]; then
  kill "$BACKUP_PID" 2>/dev/null || true
fi

exit "$EXIT_CODE"
