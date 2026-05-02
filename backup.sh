#!/bin/sh
set -e

: "${R2_ENDPOINT:?R2_ENDPOINT is required}"
: "${R2_BUCKET:?R2_BUCKET is required}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is required}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is required}"
: "${DB_PATH:?DB_PATH is required}"

R2_PREFIX="${R2_PREFIX:-newapi}"
BACKUP_INTERVAL_SECONDS="${BACKUP_INTERVAL_SECONDS:-21600}"

TMP_DIR="/tmp/newapi-backup"

mkdir -p "$TMP_DIR"

echo "Backup service started"
echo "DB_PATH=$DB_PATH"
echo "R2_ENDPOINT=$R2_ENDPOINT"
echo "R2_BUCKET=$R2_BUCKET"
echo "R2_PREFIX=$R2_PREFIX"
echo "BACKUP_INTERVAL_SECONDS=$BACKUP_INTERVAL_SECONDS"

backup_once() {
  echo "Starting backup at $(date)"

  if [ ! -f "$DB_PATH" ]; then
    echo "Database file not found: $DB_PATH"
    return 1
  fi

  TIME="$(date +%Y%m%d-%H%M%S)"
  TMP_DB="$TMP_DIR/one-api-$TIME.db"
  TMP_GZ="$TMP_DB.gz"

  sqlite3 "$DB_PATH" ".backup '$TMP_DB'"

  gzip "$TMP_DB"

  aws \
    --endpoint-url "$R2_ENDPOINT" \
    s3 cp "$TMP_GZ" "s3://$R2_BUCKET/$R2_PREFIX/one-api-$TIME.db.gz"

  rm -f "$TMP_GZ"

  echo "Backup finished at $(date)"
}

while true; do
  backup_once || echo "Backup failed at $(date)"

  echo "Sleeping ${BACKUP_INTERVAL_SECONDS}s..."
  sleep "$BACKUP_INTERVAL_SECONDS"
done
