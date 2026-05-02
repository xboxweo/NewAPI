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

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
export AWS_EC2_METADATA_DISABLED="${AWS_EC2_METADATA_DISABLED:-true}"
export AWS_PAGER=""

DB_PATH="${DB_PATH:-/data/one-api.db}"
R2_PREFIX="${R2_PREFIX:-newapi}"
BACKUP_INTERVAL_SECONDS="${BACKUP_INTERVAL_SECONDS:-21600}"
BACKUP_KEEP_COUNT="${BACKUP_KEEP_COUNT:-3}"
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
log "BACKUP_KEEP_COUNT=$BACKUP_KEEP_COUNT"
log "WAIT_FOR_INIT=$WAIT_FOR_INIT"
log "NEW_API_BIN=$NEW_API_BIN"

list_backup_objects() {
  aws \
    --endpoint-url "$R2_ENDPOINT" \
    s3api list-objects-v2 \
    --bucket "$R2_BUCKET" \
    --prefix "$S3_PREFIX" \
    --query 'Contents[].[LastModified,Key]' \
    --output text 2>/dev/null \
    | awk '$2 ~ /\.db\.gz$/ {print $1 "\t" $2}' \
    | sort
}

get_latest_backup_key() {
  objects="$(list_backup_objects)" || return 1

  if [ -z "$objects" ]; then
    return 2
  fi

  printf '%s\n' "$objects" | tail -n 1 | awk -F '\t' '{print $2}'
}

prune_old_backups() {
  log "Checking old backups for pruning..."

  objects="$(list_backup_objects)" || {
    log "Failed to list backups, skip pruning"
    return 1
  }

  if [ -z "$objects" ]; then
    log "No backups found, skip pruning"
    return 0
  fi

  total="$(printf '%s\n' "$objects" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [ "$total" -le "$BACKUP_KEEP_COUNT" ] 2>/dev/null; then
    log "Backup count is $total, no pruning needed"
    return 0
  fi

  delete_keys="$(printf '%s\n' "$objects" | awk -F '\t' -v keep="$BACKUP_KEEP_COUNT" '
    NF >= 2 {
      keys[++n] = $2
    }
    END {
      limit = n - keep
      for (i = 1; i <= limit; i++) {
        print keys[i]
      }
    }
  ')"

  if [ -z "$delete_keys" ]; then
    log "No backup needs to be deleted"
    return 0
  fi

  echo "$delete_keys" | while IFS= read -r key; do
    if [ -n "$key" ]; then
      log "Deleting old backup: s3://$R2_BUCKET/$key"

      aws \
        --endpoint-url "$R2_ENDPOINT" \
        s3api delete-object \
        --bucket "$R2_BUCKET" \
        --key "$key" >/dev/null || {
          log "Failed to delete old backup: $key"
        }
    fi
  done

  log "Pruning finished, kept latest $BACKUP_KEEP_COUNT backups"
  return 0
}

restore_latest_backup() {
  log "Checking latest backup from R2..."

  latest_key="$(get_latest_backup_key)"
  status="$?"

  if [ "$status" = "2" ]; then
    log "No remote backup found"
    return 2
  fi

  if [ "$status" != "0" ]; then
    log "Failed to check remote backups"
    return 1
  fi

  if [ -z "$latest_key" ]; then
    log "No remote backup found"
    return 2
  fi

  log "Latest remote backup: s3://$R2_BUCKET/$latest_key"

  restore_gz="$TMP_DIR/restore.db.gz"
  restore_db="$TMP_DIR/restore.db"

  rm -f "$restore_gz" "$restore_db"

  aws \
    --endpoint-url "$R2_ENDPOINT" \
    s3 cp "s3://$R2_BUCKET/$latest_key" "$restore_gz" || {
      log "Download latest backup failed"
      return 1
    }

  gzip -dc "$restore_gz" > "$restore_db" || {
    log "Unzip backup failed"
    return 1
  }

  integrity_result="$(sqlite3 "$restore_db" "PRAGMA integrity_check;" 2>/dev/null || true)"

  if [ "$integrity_result" != "ok" ]; then
    log "SQLite integrity check failed: $integrity_result"
    return 1
  fi

  db_dir="$(dirname "$DB_PATH")"
  mkdir -p "$db_dir"

  if [ -f "$DB_PATH" ]; then
    local_bak="$DB_PATH.before-restore-$(date +%Y%m%d-%H%M%S)"
    log "Local database exists, saving copy to $local_bak"
    cp "$DB_PATH" "$local_bak" || {
      log "Failed to save local database copy"
      return 1
    }
  fi

  cp "$restore_db" "$DB_PATH" || {
    log "Failed to restore database to $DB_PATH"
    return 1
  }

  log "Restore finished: $DB_PATH"
  return 0
}

backup_once() {
  backup_type="${1:-scheduled}"

  log "Starting $backup_type backup..."

  if [ ! -f "$DB_PATH" ]; then
    log "Database file not found: $DB_PATH"
    return 1
  fi

  integrity_result="$(sqlite3 "$DB_PATH" "PRAGMA integrity_check;" 2>/dev/null || true)"

  if [ "$integrity_result" != "ok" ]; then
    log "Current database integrity check failed: $integrity_result"
    return 1
  fi

  time_tag="$(date +%Y%m%d-%H%M%S)"
  tmp_db="$TMP_DIR/one-api-$time_tag.db"
  tmp_gz="$tmp_db.gz"
  object_key="${S3_PREFIX}one-api-$time_tag.db.gz"

  rm -f "$tmp_db" "$tmp_gz"

  sqlite3 "$DB_PATH" ".backup '$tmp_db'" || {
    log "SQLite backup failed"
    rm -f "$tmp_db" "$tmp_gz"
    return 1
  }

  gzip -f "$tmp_db" || {
    log "gzip failed"
    rm -f "$tmp_db" "$tmp_gz"
    return 1
  }

  aws \
    --endpoint-url "$R2_ENDPOINT" \
    s3 cp "$tmp_gz" "s3://$R2_BUCKET/$object_key" || {
      log "Upload to R2 failed"
      rm -f "$tmp_gz"
      return 1
    }

  rm -f "$tmp_gz"

  log "Backup uploaded: s3://$R2_BUCKET/$object_key"
  log "$backup_type backup finished"

  prune_old_backups || log "Prune old backups failed"

  return 0
}

ensure_app_running() {
  if [ -n "$APP_PID" ]; then
    if ! kill -0 "$APP_PID" 2>/dev/null; then
      log "New API process is not running"
      exit 1
    fi
  fi
}

wait_for_db() {
  log "Waiting for database file: $DB_PATH"

  while [ ! -f "$DB_PATH" ]; do
    ensure_app_running
    log "Database file not found yet"
    sleep 5
  done

  log "Database file found"
}

wait_for_init() {
  if [ "$WAIT_FOR_INIT" != "true" ]; then
    log "WAIT_FOR_INIT=false, skip initialization check"
    return 0
  fi

  log "Waiting for New API initialization..."

  while true; do
    ensure_app_running

    root_count="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM users WHERE role = 100 AND deleted_at IS NULL;" 2>/dev/null || echo 0)"

    if [ "$root_count" -gt 0 ] 2>/dev/null; then
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

restore_latest_backup
restore_status="$?"

case "$restore_status" in
  0)
    REMOTE_BACKUP_EXISTS="true"
    log "Remote backup restored successfully"
    prune_old_backups || log "Prune old backups failed"
    ;;
  2)
    REMOTE_BACKUP_EXISTS="false"
    log "No remote backup exists"
    ;;
  *)
    log "Remote backup check or restore failed, exiting to avoid data loss"
    exit 1
    ;;
esac

log "Starting New API..."
"$NEW_API_BIN" "$@" &

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
exit_code="$?"

log "New API exited with code $exit_code"

if [ -n "$BACKUP_PID" ]; then
  kill "$BACKUP_PID" 2>/dev/null || true
fi

exit "$exit_code"
