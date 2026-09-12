#!/usr/bin/env bash
set -euo pipefail

BACKUP_FILE=""
PGDATA=""
RESTORE_CONFIG=false

TMP_DIR=""
RESTORE_ROOT=""
OLD_PGDATA=""
FAILED_PGDATA=""
PG_SERVICE=""
PG_VERIFYBACKUP=""

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

error() {
    printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

usage() {
    cat <<EOF
Usage:
  $(basename "$0") --backup FILE --pg-data DIRECTORY [OPTIONS]

Required:
  --backup FILE       PostgreSQL physical backup archive
  --pg-data DIRECTORY PostgreSQL data directory

Optional:
  --restore-config    Restore PostgreSQL configuration from backup
  -h, --help          Show this help

Example:
  $(basename "$0") \
    --backup /backup/postgres_basebackup_2026-09-08_21-39-20.tar \
    --pg-data /var/lib/pgsql/17/data

  $(basename "$0") \
    --backup /backup/postgres_basebackup_2026-09-08_21-39-20.tar \
    --pg-data /var/lib/pgsql/17/data \
    --restore-config
EOF
}

cleanup() {
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

rollback() {
    error "Restore failed, attempting rollback"

    if [[ -n "${PGDATA:-}" && -d "$PGDATA" ]]; then
        mv "$PGDATA" "$FAILED_PGDATA"
        log "Failed restore preserved at: $FAILED_PGDATA"
    fi

    if [[ -n "${OLD_PGDATA:-}" && -d "$OLD_PGDATA" ]]; then
        mv "$OLD_PGDATA" "$PGDATA"
        log "Original PostgreSQL data directory restored"
    fi

    if [[ -n "${PG_SERVICE:-}" ]]; then
        systemctl start "$PG_SERVICE" || true
    fi
}

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backup)
            [[ $# -ge 2 ]] || {
                error "--backup requires an argument"
                usage
                exit 1
            }
            BACKUP_FILE="$2"
            shift 2
            ;;

        --pg-data)
            [[ $# -ge 2 ]] || {
                error "--pg-data requires an argument"
                usage
                exit 1
            }
            PGDATA="$2"
            shift 2
            ;;

        --restore-config)
            RESTORE_CONFIG=true
            shift
            ;;

        -h|--help)
            usage
            exit 0
            ;;

        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$BACKUP_FILE" || -z "$PGDATA" ]]; then
    usage
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
fi

for cmd in \
    awk \
    cat \
    chown \
    cp \
    date \
    find \
    mkdir \
    mktemp \
    mv \
    readlink \
    rm \
    sed \
    systemctl \
    tar
do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        error "Required command not found: $cmd"
        exit 1
    fi
done

PG_VERIFYBACKUP="$(
    find /usr \
        -type f \
        -name pg_verifybackup \
        -executable \
        2>/dev/null |
        awk 'NR == 1 {print; exit}'
)"

if [[ -z "$PG_VERIFYBACKUP" ]]; then
    error "pg_verifybackup not found"
    exit 1
fi

log "Using pg_verifybackup: $PG_VERIFYBACKUP"

if [[ ! -f "$BACKUP_FILE" ]]; then
    error "Backup file not found: $BACKUP_FILE"
    exit 1
fi

if [[ ! -r "$BACKUP_FILE" ]]; then
    error "Backup file is not readable: $BACKUP_FILE"
    exit 1
fi

log "Backup: $BACKUP_FILE"
log "Target PGDATA: $PGDATA"

TMP_DIR="$(mktemp -d /opt/pg-restore.XXXXXXXX)"
RESTORE_ROOT="$TMP_DIR/data"

mkdir -p "$RESTORE_ROOT"
mkdir -p "$RESTORE_ROOT/pg_wal"

log "Checking backup structure"

mapfile -t BACKUP_CONTENTS < <(
    tar -tf "$BACKUP_FILE"
)

BASE_ARCHIVE="$(
    printf '%s\n' "${BACKUP_CONTENTS[@]}" |
        awk '
            {
                name=$0
                sub(/^\.\//, "", name)
                if (name == "base.tar.gz") {
                    print $0
                    exit
                }
            }
        '
)"

WAL_ARCHIVE="$(
    printf '%s\n' "${BACKUP_CONTENTS[@]}" |
        awk '
            {
                name=$0
                sub(/^\.\//, "", name)
                if (name == "pg_wal.tar.gz") {
                    print $0
                    exit
                }
            }
        '
)"

MANIFEST="$(
    printf '%s\n' "${BACKUP_CONTENTS[@]}" |
        awk '
            {
                name=$0
                sub(/^\.\//, "", name)
                if (name == "backup_manifest") {
                    print $0
                    exit
                }
            }
        '
)"

CONFIG_ARCHIVE="$(
    printf '%s\n' "${BACKUP_CONTENTS[@]}" |
        awk '
            {
                name=$0
                sub(/^\.\//, "", name)
                if (name == "config.tar.gz") {
                    print $0
                    exit
                }
            }
        '
)"

if [[ -z "$BASE_ARCHIVE" ]]; then
    error "Required file 'base.tar.gz' not found in backup"
    exit 1
fi

if [[ -z "$WAL_ARCHIVE" ]]; then
    error "Required file 'pg_wal.tar.gz' not found in backup"
    exit 1
fi

if [[ -z "$MANIFEST" ]]; then
    error "Required file 'backup_manifest' not found in backup"
    exit 1
fi

log "Base archive: $BASE_ARCHIVE"
log "WAL archive: $WAL_ARCHIVE"
log "Manifest: $MANIFEST"

if [[ -n "$CONFIG_ARCHIVE" ]]; then
    log "Config archive: $CONFIG_ARCHIVE"
fi

for item in "${BACKUP_CONTENTS[@]}"; do
    normalized="$item"
    normalized="${normalized#./}"

    case "$normalized" in
        ""|base.tar.gz|pg_wal.tar.gz|backup_manifest|config.tar.gz)
            ;;
        *)
            error "Unsupported item in backup: $item"
            error "Tablespace archives and other additional files are not supported"
            exit 1
            ;;
    esac
done

log "Extracting base backup"

tar -xOf "$BACKUP_FILE" "$BASE_ARCHIVE" |
    tar -xzf - -C "$RESTORE_ROOT"

log "Extracting WAL"

tar -xOf "$BACKUP_FILE" "$WAL_ARCHIVE" |
    tar -xzf - -C "$RESTORE_ROOT/pg_wal"

log "Extracting backup manifest"

tar -xOf "$BACKUP_FILE" "$MANIFEST" \
    > "$RESTORE_ROOT/backup_manifest"

if [[ -n "$CONFIG_ARCHIVE" ]]; then
    log "Extracting configuration archive"

    mkdir -p "$TMP_DIR/config"

    tar -xOf "$BACKUP_FILE" "$CONFIG_ARCHIVE" |
        tar -xzf - -C "$TMP_DIR/config"
fi

if [[ ! -f "$RESTORE_ROOT/PG_VERSION" ]]; then
    error "Restored data directory does not contain PG_VERSION"
    exit 1
fi

log "PostgreSQL version in backup: $(cat "$RESTORE_ROOT/PG_VERSION")"

log "Verifying backup"

"$PG_VERIFYBACKUP" "$RESTORE_ROOT"

log "Backup verification successful"

PGDATA="$(readlink -f "$PGDATA")"
OLD_PGDATA="${PGDATA}.orig"
FAILED_PGDATA="${PGDATA}.failed.$(date '+%Y-%m-%d_%H-%M-%S')"

if [[ -e "$OLD_PGDATA" ]]; then
    error "Backup directory already exists: $OLD_PGDATA"
    exit 1
fi

PG_SERVICE="$(
    systemctl list-units \
        --type=service \
        --state=active \
        --no-legend \
        'postgresql*.service' |
        awk 'NR == 1 {print $1}'
)"

if [[ -z "$PG_SERVICE" ]]; then
    error "Active PostgreSQL service not found"
    exit 1
fi

log "Detected active PostgreSQL service: $PG_SERVICE"

log "Stopping PostgreSQL"

systemctl stop "$PG_SERVICE"

if systemctl is-active --quiet "$PG_SERVICE"; then
    error "PostgreSQL service is still active"
    exit 1
fi

if [[ -d "$PGDATA" ]]; then
    log "Moving current PGDATA to: $OLD_PGDATA"
    mv "$PGDATA" "$OLD_PGDATA"
fi

log "Installing restored PostgreSQL data"

mv "$RESTORE_ROOT" "$PGDATA"

chown -R postgres:postgres "$PGDATA"
chmod 700 "$PGDATA"

if [[ "$RESTORE_CONFIG" == true ]]; then
    if [[ -z "$CONFIG_ARCHIVE" ]]; then
        error "--restore-config specified, but config.tar.gz is missing"
        rollback
        exit 1
    fi

    log "Restoring PostgreSQL configuration"

    cp -a "$TMP_DIR/config/." "$PGDATA/"

    mkdir -p "$PGDATA/conf.d"

    chown -R postgres:postgres "$PGDATA"

    if [[ -f "$PGDATA/postgresql.conf" ]]; then
        sed -i \
            '/^[[:space:]]*data_directory[[:space:]]*=/d' \
            "$PGDATA/postgresql.conf"
    fi
fi

log "Starting PostgreSQL"

if ! systemctl start "$PG_SERVICE"; then
    rollback
    exit 1
fi

if ! systemctl is-active --quiet "$PG_SERVICE"; then
    rollback
    exit 1
fi

log "PostgreSQL started successfully"
log "Restore completed successfully"
log "Original data directory: $OLD_PGDATA"
