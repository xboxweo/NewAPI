#!/bin/sh
set -eu

DB_PATH="${DB_PATH:-/data/newapi/one-api.db}"
BACKUP_NAME="${BACKUP_NAME:-one-api}"
BACKUP_DIR="${BACKUP_DIR:-/tmp/sqlite-backup}"
BACKUP_FILE="$BACKUP_DIR/${BACKUP_NAME}.db"

RESTORE_DIR="${RESTORE_DIR:-/tmp/restic-restore}"
RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/tmp/restic-cache}"
RESTIC_HOST="${RESTIC_HOST:-new-api}"

KEEP_LAST="${KEEP_LAST:-5}"

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

check_backup_time_format() {
    if [ -n "${BACKUP_TIME:-}" ]; then
        case "$BACKUP_TIME" in
            [0-2][0-9]:[0-5][0-9]|[0-9]:[0-5][0-9])
                ;;
            *)
                log "invalid BACKUP_TIME: $BACKUP_TIME, expected format: HH:MM"
                exit 1
                ;;
        esac
    fi
}

init_repo_if_needed() {
    if [ "${RESTIC_INIT:-0}" = "1" ]; then
        log "checking restic repository"

        if ! restic --cache-dir "$RESTIC_CACHE_DIR" snapshots >/dev/null 2>&1; then
            log "initializing restic repository"
            restic --cache-dir "$RESTIC_CACHE_DIR" init
        else
            log "restic repository already initialized"
        fi
    fi
}

restore_latest() {
    log "RESTORE_ON_START=1, restoring latest backup from remote repository"

    rm -rf "$RESTORE_DIR"
    mkdir -p "$RESTORE_DIR"

    if ! restic --cache-dir "$RESTIC_CACHE_DIR" restore latest \
        --target "$RESTORE_DIR" \
        --host "$RESTIC_HOST" \
        --tag sqlite \
        --tag newapi \
        --tag "$BACKUP_NAME"; then

        log "no backup restored from remote repository"

        if [ "${RESTORE_REQUIRED:-0}" = "1" ]; then
            log "RESTORE_REQUIRED=1, exiting"
            exit 1
        fi

        log "skip restore and continue"
        return 0
    fi

    RESTORED_FILE="$RESTORE_DIR$BACKUP_FILE"

    if [ ! -f "$RESTORED_FILE" ]; then
        RESTORED_FILE="$(find "$RESTORE_DIR" -type f -name "${BACKUP_NAME}.db" | sort | tail -n 1 || true)"
    fi

    if [ -z "${RESTORED_FILE:-}" ] || [ ! -f "$RESTORED_FILE" ]; then
        log "restored file not found"

        if [ "${RESTORE_REQUIRED:-0}" = "1" ]; then
            exit 1
        fi

        return 0
    fi

    DB_DIR="$(dirname "$DB_PATH")"
    mkdir -p "$DB_DIR"

    TMP_DB="${DB_PATH}.restore.tmp"

    log "overwriting local database"
    log "source: $RESTORED_FILE"
    log "target: $DB_PATH"

    cat "$RESTORED_FILE" > "$TMP_DB"
    mv -f "$TMP_DB" "$DB_PATH"

    rm -f "${DB_PATH}-wal" "${DB_PATH}-shm"

    log "restore finished"
}

backup_once() {
    log "starting sqlite backup"
    log "SQLite DB: $DB_PATH"
    log "Backup file: $BACKUP_FILE"

    if [ ! -f "$DB_PATH" ]; then
        log "database file not found: $DB_PATH"
        exit 1
    fi

    mkdir -p "$BACKUP_DIR"

    TMP_BACKUP_FILE="${BACKUP_FILE}.tmp"

    rm -f "$TMP_BACKUP_FILE" "$BACKUP_FILE"

    sqlite3 "$DB_PATH" <<EOF
.timeout 10000
.backup '$TMP_BACKUP_FILE'
EOF

    mv -f "$TMP_BACKUP_FILE" "$BACKUP_FILE"

    log "uploading backup to remote repository"

    restic --cache-dir "$RESTIC_CACHE_DIR" backup "$BACKUP_FILE" \
        --host "$RESTIC_HOST" \
        --tag sqlite \
        --tag newapi \
        --tag "$BACKUP_NAME"

    if [ "${RESTIC_FORGET:-1}" = "1" ]; then
        log "applying retention policy: keep last $KEEP_LAST backups"

        restic --cache-dir "$RESTIC_CACHE_DIR" forget \
            --host "$RESTIC_HOST" \
            --tag sqlite \
            --tag newapi \
            --tag "$BACKUP_NAME" \
            --group-by host,tags \
            --keep-last "$KEEP_LAST" \
            --prune
    fi

    rm -f "$BACKUP_FILE"

    log "backup finished"
}

check_backup_time_format
init_repo_if_needed

if [ "${RESTORE_ON_START:-1}" = "1" ]; then
    restore_latest
fi

if [ "${RESTORE_ONLY:-0}" = "1" ]; then
    log "RESTORE_ONLY=1, exiting after restore"
    exit 0
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
