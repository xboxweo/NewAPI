#!/bin/sh
set -eu

DB_PATH="${DB_PATH:-/data/newapi/one-api.db}"
BACKUP_NAME="${BACKUP_NAME:-one-api}"
BACKUP_DIR="${BACKUP_DIR:-/tmp/sqlite-backup}"
BACKUP_FILE="${BACKUP_DIR}/${BACKUP_NAME}.db"

RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/tmp/restic-cache}"
RESTIC_HOST="${RESTIC_HOST:-new-api}"

RESTORE_ON_START="${RESTORE_ON_START:-1}"
RESTORE_REQUIRED="${RESTORE_REQUIRED:-0}"
RESTORE_ONLY="${RESTORE_ONLY:-0}"

RESTIC_INIT="${RESTIC_INIT:-0}"
RESTIC_FORGET="${RESTIC_FORGET:-1}"

KEEP_LAST="${KEEP_LAST:-3}"

RUN_ONCE="${RUN_ONCE:-0}"
RUN_IMMEDIATELY="${RUN_IMMEDIATELY:-0}"

BACKUP_TIME="${BACKUP_TIME:-}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-86400}"

log() {
    echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] $*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

require_env() {
    name="$1"
    value="$(eval "printf '%s' \"\${$name:-}\"")"

    if [ -z "$value" ]; then
        fail "$name is required"
    fi

    case "$value" in
        CHANGE_ME*)
            fail "$name is still placeholder, please edit Dockerfile"
            ;;
        *CHANGE_ME*)
            fail "$name contains CHANGE_ME placeholder, please edit Dockerfile"
            ;;
    esac
}

validate_config() {
    require_env RESTIC_REPOSITORY
    require_env RESTIC_PASSWORD
    require_env AWS_ACCESS_KEY_ID
    require_env AWS_SECRET_ACCESS_KEY

    if [ -n "$BACKUP_TIME" ]; then
        case "$BACKUP_TIME" in
            [0-2][0-9]:[0-5][0-9]|[0-9]:[0-5][0-9])
                BACKUP_H="${BACKUP_TIME%:*}"
                BACKUP_M="${BACKUP_TIME#*:}"

                BACKUP_H="$(echo "$BACKUP_H" | sed 's/^0*//')"
                BACKUP_M="$(echo "$BACKUP_M" | sed 's/^0*//')"

                [ -z "$BACKUP_H" ] && BACKUP_H=0
                [ -z "$BACKUP_M" ] && BACKUP_M=0

                if [ "$BACKUP_H" -gt 23 ] || [ "$BACKUP_M" -gt 59 ]; then
                    fail "invalid BACKUP_TIME: $BACKUP_TIME, expected HH:MM"
                fi
                ;;
            *)
                fail "invalid BACKUP_TIME: $BACKUP_TIME, expected HH:MM"
                ;;
        esac
    fi

    case "$INTERVAL_SECONDS" in
        ''|*[!0-9]*)
            fail "INTERVAL_SECONDS must be a positive integer"
            ;;
        *)
            if [ "$INTERVAL_SECONDS" -le 0 ]; then
                fail "INTERVAL_SECONDS must be greater than 0"
            fi
            ;;
    esac

    if [ -z "$BACKUP_TIME" ] && [ -z "$INTERVAL_SECONDS" ]; then
        fail "either BACKUP_TIME or INTERVAL_SECONDS is required"
    fi
}

restic_cmd() {
    restic --cache-dir "$RESTIC_CACHE_DIR" "$@"
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

init_restic_repo_if_needed() {
    if [ "$RESTIC_INIT" = "1" ]; then
        log "checking restic repository"

        if ! restic_cmd snapshots >/dev/null 2>&1; then
            log "initializing restic repository"
            restic_cmd init
        else
            log "restic repository already initialized"
        fi
    fi
}

restore_latest_backup() {
    log "RESTORE_ON_START=1, trying to restore latest backup from remote"

    DB_DIR="$(dirname "$DB_PATH")"
    DB_TMP="${DB_PATH}.restore.tmp"

    mkdir -p "$DB_DIR"
    rm -f "$DB_TMP"

    log "remote backup file path: $BACKUP_FILE"
    log "local database path: $DB_PATH"

    if restic_cmd dump \
        --host "$RESTIC_HOST" \
        --tag sqlite \
        --tag newapi \
        --tag "$BACKUP_NAME" \
        latest \
        "$BACKUP_FILE" > "$DB_TMP"; then

        if [ ! -s "$DB_TMP" ]; then
            log "restored file is empty, abort restore"
            rm -f "$DB_TMP"

            if [ "$RESTORE_REQUIRED" = "1" ]; then
                exit 1
            fi

            return 0
        fi

        mv -f "$DB_TMP" "$DB_PATH"
        rm -f "${DB_PATH}-wal" "${DB_PATH}-shm"

        log "restore finished, local database overwritten: $DB_PATH"
    else
        rm -f "$DB_TMP"

        log "no latest backup found or restore failed"

        if [ "$RESTORE_REQUIRED" = "1" ]; then
            log "RESTORE_REQUIRED=1, exiting"
            exit 1
        fi
    fi
}

backup_once() {
    log "starting sqlite backup"
    log "SQLite DB: $DB_PATH"
    log "temporary backup file: $BACKUP_FILE"

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

    restic_cmd backup "$BACKUP_FILE" \
        --host "$RESTIC_HOST" \
        --tag sqlite \
        --tag newapi \
        --tag "$BACKUP_NAME"

    if [ "$RESTIC_FORGET" = "1" ]; then
        log "applying retention policy: keep latest $KEEP_LAST backups"

        restic_cmd forget \
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

mkdir -p "$BACKUP_DIR" "$RESTIC_CACHE_DIR"

validate_config
init_restic_repo_if_needed

if [ "$RESTORE_ON_START" = "1" ]; then
    restore_latest_backup
else
    log "RESTORE_ON_START=0, skip restore"
fi

if [ "$RESTORE_ONLY" = "1" ]; then
    log "RESTORE_ONLY=1, exiting after restore"
    exit 0
fi

if [ "$RUN_ONCE" = "1" ]; then
    backup_once
    exit 0
fi

if [ "$RUN_IMMEDIATELY" = "1" ]; then
    log "RUN_IMMEDIATELY=1, running backup now"
    backup_once || log "backup failed"
fi

if [ -n "$BACKUP_TIME" ]; then
    log "daily backup mode enabled"
    log "BACKUP_TIME=$BACKUP_TIME"
    log "TZ=${TZ:-system-default}"

    while true; do
        WAIT_SECONDS="$(seconds_until_backup_time)"
        log "next backup at $BACKUP_TIME, sleeping ${WAIT_SECONDS}s"
        sleep "$WAIT_SECONDS"

        backup_once || log "backup failed"
    done
else
    log "interval backup mode enabled"
    log "INTERVAL_SECONDS=$INTERVAL_SECONDS"

    while true; do
        backup_once || log "backup failed"
        log "sleeping ${INTERVAL_SECONDS}s"
        sleep "$INTERVAL_SECONDS"
    done
fi
