#!/bin/sh
set -eu

DB_PATH="${DB_PATH:-/data/newapi/one-api.db}"
BACKUP_NAME="${BACKUP_NAME:-one-api}"
BACKUP_DIR="${BACKUP_DIR:-/tmp/sqlite-backup}"
RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/tmp/restic-cache}"

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is required}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD is required}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is required}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is required}"

mkdir -p "$BACKUP_DIR" "$RESTIC_CACHE_DIR"

log() {
    echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] $*"
}

strip_zero() {
    v="$1"
    v="$(echo "$v" | sed 's/^0*//')"
    [ -z "$v" ] && v=0
    echo "$v"
}

seconds_until_backup_time() {
    BACKUP_H="${BACKUP_TIME%:*}"
    BACKUP_M="${BACKUP_TIME#*:}"

    BACKUP_H="$(strip_zero "$BACKUP_H")"
    BACKUP_M="$(strip_zero "$BACKUP_M")"

    NOW_H="$(strip_zero "$(date '+%H')")"
    NOW_M="$(strip_zero "$(date '+%M')")"
    NOW_S="$(strip_zero "$(date '+%S')")"

    TARGET_SECONDS=$((BACKUP_H * 3600 + BACKUP_M * 60))
    NOW_SECONDS=$((NOW_H * 3600 + NOW_M * 60 + NOW_S))

    WAIT_SECONDS=$((TARGET_SECONDS - NOW_SECONDS))

    if [ "$WAIT_SECONDS" -le 0 ]; then
        WAIT_SECONDS=$((WAIT_SECONDS + 86400))
    fi

    echo "$WAIT_SECONDS"
}

backup_once() {
    TS="$(date '+%Y%m%d-%H%M%S')"
    BACKUP_FILE="$BACKUP_DIR/${BACKUP_NAME}-${TS}.db"

    log "SQLite DB: $DB_PATH"
    log "Backup file: $BACKUP_FILE"

    if [ ! -f "$DB_PATH" ]; then
        log "database file not found: $DB_PATH"
        exit 1
    fi

    sqlite3 "$DB_PATH" <<EOF
.timeout 10000
.backup '$BACKUP_FILE'
EOF

    log "uploading to Cloudflare R2 by restic"

    restic backup "$BACKUP_FILE" \
        --cache-dir "$RESTIC_CACHE_DIR" \
        --tag sqlite \
        --tag newapi \
        --tag one-api

    if [ "${RESTIC_FORGET:-1}" = "1" ]; then
        log "applying retention policy"

        restic forget \
            --cache-dir "$RESTIC_CACHE_DIR" \
            --prune \
            --keep-daily "${KEEP_DAILY:-7}" \
            --keep-weekly "${KEEP_WEEKLY:-4}" \
            --keep-monthly "${KEEP_MONTHLY:-6}"
    fi

    rm -f "$BACKUP_FILE"

    log "backup finished"
}

if [ "${RESTIC_INIT:-0}" = "1" ]; then
    log "checking restic repository"

    if ! restic snapshots --cache-dir "$RESTIC_CACHE_DIR" >/dev/null 2>&1; then
        log "initializing restic repository"
        restic init --cache-dir "$RESTIC_CACHE_DIR"
    fi
fi

if [ "${RUN_ONCE:-0}" = "1" ]; then
    backup_once
    exit 0
fi

if [ -n "${BACKUP_TIME:-}" ]; then
    log "daily backup mode enabled"
    log "BACKUP_TIME=$BACKUP_TIME"
    log "TZ=${TZ:-system-default}"

    if [ "${RUN_IMMEDIATELY:-0}" = "1" ]; then
        log "RUN_IMMEDIATELY=1, running backup now"
        backup_once || log "backup failed"
    fi

    while true; do
        WAIT_SECONDS="$(seconds_until_backup_time)"
        log "next backup at $BACKUP_TIME, sleeping ${WAIT_SECONDS}s"
        sleep "$WAIT_SECONDS"

        backup_once || log "backup failed"
    done
else
    INTERVAL_SECONDS="${INTERVAL_SECONDS:-86400}"

    log "interval backup mode enabled"
    log "INTERVAL_SECONDS=$INTERVAL_SECONDS"

    while true; do
        backup_once || log "backup failed"
        log "sleeping ${INTERVAL_SECONDS}s"
        sleep "$INTERVAL_SECONDS"
    done
fi
