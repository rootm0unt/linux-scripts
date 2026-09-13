#!/usr/bin/env bash
set -euo pipefail
# Default configuration
readonly DEFAULT_DB_USER="postgres"
readonly DEFAULT_BACKUP_DEST_DIR="/opt/psql-backup"
readonly DAYS_TO_KEEP=14

# !!!!! DO NOT CHANGE THESE PARAMETERS !!!!!
readonly LOCK_FILE="/tmp/postgres_backup.lock"
readonly LOG_FILE="/var/log/psql-backup.log"
readonly BACKUP_PREFIX="postgres_basebackup"
readonly TIMESTAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
readonly BACKUP_NAME="${BACKUP_PREFIX}_${TIMESTAMP}.tar"

readonly REQUIRED_COMMANDS=(
    "pg_basebackup"
    "psql"
    "tar"
    "find"
    "flock"
    "sudo"
    "awk"
    "du"
    "tee"
)

DB_USER="$DEFAULT_DB_USER"
BACKUP_DEST_DIR="$DEFAULT_BACKUP_DEST_DIR"
GOTIFY_ENABLED=false

TMP_BACKUP_DIR=""
TMP_BACKUP_PARENT_DIR=""
CONFIG_BACKUP_DIR=""
CONFIG_ARCHIVE=""
BACKUP_FILE=""
TEMP_BACKUP_FILE=""

log() {
    local message="$*"
    local timestamp

    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    printf '[%s] %s\n' "$timestamp" "$message" | tee -a "$LOG_FILE"
}

send_notification() {
    local title="$1"
    local message="$2"

    if [[ "$GOTIFY_ENABLED" != true ]]; then
        return 0
    fi

    if ! command -v gotify >/dev/null 2>&1; then
        log "[WARNING]: Gotify is enabled, but the gotify command was not found"
        return 0
    fi

    gotify push \
        -t "$title" \
        -p 5 \
        "$message" >/dev/null || true
}

handle_error() {
    local error_msg="$1"

    log "[ERROR]: ${error_msg}"

    send_notification \
        "PostgreSQL Backup | FAILED" \
        "$error_msg"

    exit 1
}

cleanup() {
    local exit_code=$?

    if [[ -n "$TMP_BACKUP_DIR" && -d "$TMP_BACKUP_DIR" ]]; then
        rm -rf -- "$TMP_BACKUP_DIR"
    fi

    if [[ -f "$TEMP_BACKUP_FILE" ]]; then
        rm -f -- "$TEMP_BACKUP_FILE"
    fi

    exit "$exit_code"
}

trap cleanup EXIT

trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

PostgreSQL physical backup utility using pg_basebackup.

Options:
    --pg-user <username>   PostgreSQL operating system user
                           Default: ${DEFAULT_DB_USER}

    --backup-dir <directory>
                           Backup destination directory
                           Default: ${DEFAULT_BACKUP_DEST_DIR}

    --gotify               Enable Gotify notifications

    -h, --help             Show this help message

Examples:

    $(basename "$0")

    $(basename "$0") --pg-user postgres

    $(basename "$0") --backup-dir /mnt/backups/postgresql

    $(basename "$0") --gotify

    $(basename "$0") --pg-user postgres --backup-dir /mnt/backups/postgresql --gotify
EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pg-user)
                if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
                    echo "Error: --pg-user requires a username" >&2
                    exit 2
                fi

                DB_USER="$2"
                shift 2
                ;;

            --backup-dir)
                if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
                    echo "Error: --backup-dir requires a directory path" >&2
                    exit 2
                fi

                BACKUP_DEST_DIR="${2%/}"
                shift 2
                ;;

            --gotify)
                GOTIFY_ENABLED=true
                shift
                ;;

            -h|--help)
                usage
                exit 0
                ;;

            *)
                echo "Error: unknown option: $1" >&2
                echo
                usage >&2
                exit 2
                ;;
        esac
    done
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Error: this script must be run as root" >&2
        exit 1
    fi
}

check_dependencies() {
    log "Checking dependencies"

    local command

    for command in "${REQUIRED_COMMANDS[@]}"; do
        if ! command -v "$command" >/dev/null 2>&1; then
            handle_error "Required command not found: $command"
        fi
    done

    if ! id "$DB_USER" >/dev/null 2>&1; then
        handle_error "PostgreSQL user not found: $DB_USER"
    fi

    log "Dependency check passed"
}

acquire_lock() {
    exec 9>"$LOCK_FILE"

    if ! flock -n 9; then
        handle_error "Another backup process is already running"
    fi
}

prepare_environment() {
    log "Environment setup"

    mkdir -p -- "$BACKUP_DEST_DIR"

    TMP_BACKUP_PARENT_DIR="${BACKUP_DEST_DIR}/.tmp"

    mkdir -p -- "$TMP_BACKUP_PARENT_DIR"

    BACKUP_FILE="${BACKUP_DEST_DIR}/${BACKUP_NAME}"
    TEMP_BACKUP_FILE="${BACKUP_FILE}.tmp"

    chown "$DB_USER:$DB_USER" "$BACKUP_DEST_DIR"
    chown "$DB_USER:$DB_USER" "$TMP_BACKUP_PARENT_DIR"

    chmod 750 "$BACKUP_DEST_DIR"
    chmod 700 "$TMP_BACKUP_PARENT_DIR"

    TMP_BACKUP_DIR="${TMP_BACKUP_PARENT_DIR}/backup_${TIMESTAMP}"

    sudo -u "$DB_USER" mkdir -p -- "$TMP_BACKUP_DIR"
    sudo -u "$DB_USER" chmod 700 "$TMP_BACKUP_DIR"
}

create_backup() {
    log "Creating a backup using pg_basebackup"

    if ! sudo -u "$DB_USER" pg_basebackup \
        -D "$TMP_BACKUP_DIR" \
        -Ft \
        -z \
        -Xs \
        -P; then

        handle_error "An error occurred while creating the PostgreSQL backup"
    fi

    log "pg_basebackup completed successfully"

    if [[ ! -f "$TMP_BACKUP_DIR/base.tar.gz" ]]; then
        handle_error "pg_basebackup finished, but base.tar.gz was not created"
    fi

    if [[ ! -f "$TMP_BACKUP_DIR/pg_wal.tar.gz" ]]; then
        handle_error "pg_basebackup finished, but pg_wal.tar.gz was not created"
    fi

    if [[ ! -f "$TMP_BACKUP_DIR/backup_manifest" ]]; then
        handle_error "pg_basebackup finished, but backup_manifest was not created"
    fi

    local backup_size

    backup_size="$(du -sh "$TMP_BACKUP_DIR" | awk '{print $1}')"

    log "Temporary backup size: ${backup_size}"
}

create_config_backup() {
    log "Collecting PostgreSQL configuration files"

    local config_file
    local hba_file
    local ident_file

    CONFIG_BACKUP_DIR="${TMP_BACKUP_DIR}/config"
    CONFIG_ARCHIVE="${TMP_BACKUP_DIR}/config.tar.gz"

    sudo -u "$DB_USER" mkdir -p -- "$CONFIG_BACKUP_DIR"
    sudo -u "$DB_USER" chmod 700 "$CONFIG_BACKUP_DIR"

    config_file="$(sudo -u "$DB_USER" psql -Atqc "SHOW config_file")" || \
        handle_error "Failed to determine PostgreSQL configuration file"

    hba_file="$(sudo -u "$DB_USER" psql -Atqc "SHOW hba_file")" || \
        handle_error "Failed to determine PostgreSQL HBA file"

    ident_file="$(sudo -u "$DB_USER" psql -Atqc "SHOW ident_file")" || \
        handle_error "Failed to determine PostgreSQL ident file"

    if [[ ! -f "$config_file" ]]; then
        handle_error "PostgreSQL configuration file not found: ${config_file}"
    fi

    if [[ ! -f "$hba_file" ]]; then
        handle_error "PostgreSQL HBA file not found: ${hba_file}"
    fi

    if [[ ! -f "$ident_file" ]]; then
        handle_error "PostgreSQL ident file not found: ${ident_file}"
    fi

    log "PostgreSQL configuration file: ${config_file}"
    log "PostgreSQL HBA file: ${hba_file}"
    log "PostgreSQL ident file: ${ident_file}"

    if ! cp -L -- "$config_file" \
        "$CONFIG_BACKUP_DIR/postgresql.conf"; then

        handle_error "Failed to copy postgresql.conf"
    fi

    if ! cp -L -- "$hba_file" \
        "$CONFIG_BACKUP_DIR/pg_hba.conf"; then

        handle_error "Failed to copy pg_hba.conf"
    fi

    if ! cp -L -- "$ident_file" \
        "$CONFIG_BACKUP_DIR/pg_ident.conf"; then

        handle_error "Failed to copy pg_ident.conf"
    fi

    chown "$DB_USER:$DB_USER" \
        "$CONFIG_BACKUP_DIR/postgresql.conf" \
        "$CONFIG_BACKUP_DIR/pg_hba.conf" \
        "$CONFIG_BACKUP_DIR/pg_ident.conf"

    chmod 600 \
        "$CONFIG_BACKUP_DIR/postgresql.conf" \
        "$CONFIG_BACKUP_DIR/pg_hba.conf" \
        "$CONFIG_BACKUP_DIR/pg_ident.conf"

    log "Creating configuration archive"

    if ! sudo -u "$DB_USER" tar -czf "$CONFIG_ARCHIVE" \
        -C "$CONFIG_BACKUP_DIR" \
        postgresql.conf \
        pg_hba.conf \
        pg_ident.conf; then

        handle_error "Failed to create PostgreSQL configuration archive"
    fi

    rm -rf -- "$CONFIG_BACKUP_DIR"

    log "PostgreSQL configuration archive created: ${CONFIG_ARCHIVE}"
}

verify_backup() {
    log "Verifying backup archives"

    if ! tar -tzf "$TMP_BACKUP_DIR/base.tar.gz" >/dev/null; then
        handle_error "Base backup archive integrity check failed"
    fi

    if ! tar -tzf "$TMP_BACKUP_DIR/pg_wal.tar.gz" >/dev/null; then
        handle_error "WAL backup archive integrity check failed"
    fi

    if ! tar -tzf "$TMP_BACKUP_DIR/config.tar.gz" >/dev/null; then
        handle_error "PostgreSQL configuration archive integrity check failed"
    fi

    log "Backup archives verification passed"
}

store_backup() {
    log "Creating final backup archive"

    if ! tar -cf "$TEMP_BACKUP_FILE" \
        -C "$TMP_BACKUP_DIR" \
        .; then

        handle_error "Failed to create final backup archive"
    fi

    chown "$DB_USER:$DB_USER" "$TEMP_BACKUP_FILE"
    chmod 640 "$TEMP_BACKUP_FILE"

    log "Verifying final backup archive"

    if ! tar -tf "$TEMP_BACKUP_FILE" >/dev/null; then
        handle_error "Final backup archive integrity check failed"
    fi

    if ! mv -- "$TEMP_BACKUP_FILE" "$BACKUP_FILE"; then
        handle_error "Failed to move final backup archive into ${BACKUP_DEST_DIR}"
    fi

    log "PostgreSQL backup saved: ${BACKUP_FILE}"

    local final_size

    final_size="$(du -sh "$BACKUP_FILE" | awk '{print $1}')"

    log "Final backup size: ${final_size}"
}

cleanup_old_backups() {
    log "Deleting backups older than ${DAYS_TO_KEEP} days"

    find "$BACKUP_DEST_DIR" \
        -maxdepth 1 \
        -type f \
        -name "${BACKUP_PREFIX}_*.tar" \
        -mtime "+${DAYS_TO_KEEP}" \
        -print \
        -delete
}

main() {
    check_root
    parse_arguments "$@"

    log "Starting a PostgreSQL backup job"
    log "PostgreSQL user: ${DB_USER}"
    log "Backup directory: ${BACKUP_DEST_DIR}"
    log "Gotify notifications: ${GOTIFY_ENABLED}"

    check_dependencies
    acquire_lock
    prepare_environment
    create_backup
    create_config_backup
    verify_backup
    store_backup
    cleanup_old_backups

    log "The PostgreSQL backup job has completed successfully"

    send_notification \
        "PostgreSQL Backup | SUCCESS" \
        "Backup: ${BACKUP_NAME}
Size: $(du -sh "$BACKUP_FILE" | awk '{print $1}')
Retention: ${DAYS_TO_KEEP} days"
}

main "$@"

