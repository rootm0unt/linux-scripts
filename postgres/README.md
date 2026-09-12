# PostgreSQL Backup & Restore

A set of Bash scripts for creating and restoring physical PostgreSQL backups.

The project consists of two main tools:

* `psql-backup.sh` — creates physical backups using `pg_basebackup`;
* `psql-restore.sh` — restores backups with prior verification using `pg_verifybackup`.

The repository also includes ready-to-use systemd units for automated backups.

## Features

### Backup

`psql-backup.sh`:

* creates physical PostgreSQL backups using `pg_basebackup`;
* uses tar format with gzip compression;
* preserves WAL and `backup_manifest`;
* preserves the main PostgreSQL configuration files;
* verifies the integrity of the created archives;
* supports retention of old backups;
* prevents parallel execution;
* supports Gotify notifications;
* can be run manually or through any scheduler.

### Restore

`psql-restore.sh`:

* validates the backup structure;
* extracts the physical backup into a temporary directory;
* verifies it using `pg_verifybackup`;
* automatically detects the active `postgresql*.service`;
* preserves the current `PGDATA` before replacement;
* installs the restored data;
* starts PostgreSQL after the restore;
* attempts to perform a rollback if PostgreSQL fails to start;
* optionally restores the PostgreSQL configuration.

## Requirements

The scripts are intended to be run as `root` or with the appropriate `sudo` privileges.

Backup requires:

* PostgreSQL;
* `pg_basebackup`;
* `psql`;
* `tar`;
* `find`;
* `flock`;
* `sudo`;
* `awk`;
* `du`;
* `tee`.

Restore additionally requires:

* `pg_verifybackup`;
* `systemd`.

The restore script automatically searches for `pg_verifybackup` under `/usr`, so typical Debian/Ubuntu and RHEL paths are supported, for example:

```bash
/usr/lib/postgresql/17/bin/
# or
/usr/pgsql-17/bin/pg_verifybackup
```

## Installation

### Backup

```bash
wget -O /usr/local/bin/psql-backup https://raw.githubusercontent.com/rootm0unt/linux-scripts/main/postgres/psql-backup.sh

chmod +x /usr/local/bin/psql-backup
```

Check:

```bash
psql-backup --help
```

### Restore

```bash
wget -O /usr/local/bin/psql-restore https://raw.githubusercontent.com/rootm0unt/linux-scripts/main/postgres/psql-restore.sh

chmod +x /usr/local/bin/psql-restore
```

Check:

```bash
psql-restore --help
```

# Backup

## Usage

When run without arguments, the default values are used.

Options:

```bash
--pg-user <username>       PostgreSQL OS user
                           Default: postgres

--backup-dir <directory>   Backup destination
                           Default: /opt/psql-backup

--gotify                   Enable Gotify notifications

-h, --help                 Show help
```

Examples:

```bash
psql-backup

psql-backup --backup-dir /mnt/backups/postgresql

psql-backup --pg-user postgres --backup-dir /mnt/backups/postgresql --gotify
```

## Backup format

A completed backup has the following format:

```bash
postgres_basebackup_YYYY-MM-DD_HH-MM-SS.tar
```

The archive contains:

```bash
base.tar.gz
pg_wal.tar.gz
backup_manifest
config.tar.gz
```

`config.tar.gz` contains:

```bash
postgresql.conf
pg_hba.conf
pg_ident.conf
```

The paths to the configuration files are obtained directly from PostgreSQL:

```sql
SHOW config_file;
SHOW hba_file;
SHOW ident_file;
```

Therefore, the configuration files may be located outside `PGDATA`.

## Backup verification

Before creating the final archive, each individual tar.gz archive is checked:

```bash
tar -tzf base.tar.gz
tar -tzf pg_wal.tar.gz
tar -tzf config.tar.gz
```

After the final `.tar` archive is created, its contents are also verified.

This verifies archive integrity but **does not replace a test restore**. For critical systems, it is recommended to periodically perform a full restore on a separate server.

## Retention and disk space

By default, backups are retained for 14 days:

```bash
DAYS_TO_KEEP=14
```

Only `postgres_basebackup_*.tar` files older than the specified retention period are removed.

If necessary, the value can be changed, for example:

```bash
# one week
DAYS_TO_KEEP=7
# or one month:
DAYS_TO_KEEP=30
```

Physical backups can consume a significant amount of disk space, because during the backup process space is required simultaneously for:

1. the temporary `pg_basebackup` result;
2. the final `.tar` archive;
3. existing retained backups.

Before configuring automated backups, make sure that the storage has sufficient free space.

## Gotify

Notifications use the official [Gotify-CLI](https://github.com/gotify/cli).

The utility must be **installed and configured in advance** for the required Gotify server.

You can test notifications with:

```bash
gotify push "PostgreSQL backup test"
```

Notifications are enabled with:

```bash
psql-backup --gotify
```

If `--gotify` is specified but `gotify` is not available in `PATH`, the backup job does not fail. The script logs a warning that the utility is not available and continues without notifications.

# Automation

Automated execution through systemd is **optional**. The script itself does not depend on systemd and can be run manually, through cron, Ansible, or any other scheduler.

The project provides:

```bash
psql-backup.service
psql-backup.timer
```

Installation:

```bash
# service:
wget -O /etc/systemd/system/psql-backup.service https://raw.githubusercontent.com/rootm0unt/linux-scripts/main/postgres/psql-backup.service

# timer:
wget -O /etc/systemd/system/psql-backup.timer https://raw.githubusercontent.com/rootm0unt/linux-scripts/main/postgres/psql-backup.timer

# reload systemd configuration:
systemctl daemon-reload
systemctl enable --now psql-backup.timer

# Check:
systemctl list-timers psql-backup.timer
```

## systemd Configuration

Backup parameters are specified directly in `ExecStart`.

For example:

```ini
[Service]
Type=oneshot
ExecStart=/usr/local/bin/psql-backup --backup-dir /mnt/backups/postgresql --gotify
```

If the default values are suitable, the following is sufficient:

```ini
[Service]
Type=oneshot
ExecStart=/usr/local/bin/psql-backup
```

In this case, the following values are used:

```bash
--pg-user postgres
--backup-dir /opt/psql-backup
```

**Before enabling the timer, check `ExecStart` and specify your required parameter values.**

The schedule is configured in `psql-backup.timer`, for example:

```ini
[Unit]
Description=Run PostgreSQL backup periodically

[Timer]
OnCalendar=*-*-* 00:20:00
Persistent=true
RandomizedDelaySec=5m

[Install]
WantedBy=timers.target
```

After modifying a unit:

```bash
systemctl daemon-reload
systemctl restart psql-backup.timer
```

Manual execution:

```bash
systemctl start psql-backup.service
```

Logs:

```bash
journalctl -u psql-backup.service
```

## Locking

The script prevents parallel execution using:

```bash
/tmp/psql-backup.lock
```

If another backup instance is already running, a new execution exits with an error.

Main log:

```bash
/var/log/psql-backup.log
```

# Restore

## Usage

`psql-restore` requires two parameters:

```bash
--backup FILE
--pg-data DIRECTORY
```

Example:

```bash
psql-restore --backup /opt/pg-backup/postgres_basebackup_2026-09-08_02-53-57.tar \
    --pg-data /var/lib/postgresql/17/main
```

Full list of options:

```bash
Usage:
  psql-restore --backup FILE --pg-data DIRECTORY [OPTIONS]

Required:
  --backup FILE       PostgreSQL physical backup archive
  --pg-data DIRECTORY PostgreSQL data directory

Optional:
  --restore-config    Restore PostgreSQL configuration from backup
  -h, --help          Show this help
```

`--pg-data` must be specified explicitly. The script **does not attempt to automatically locate `PGDATA`**.

Example for Debian/Ubuntu:

```bash
/var/lib/postgresql/17/main
```

On RHEL-based systems:

```bash
/var/lib/pgsql/17/data
```

## Restore Process

Before stopping PostgreSQL, the backup is fully extracted into a temporary directory and verified using `pg_verifybackup`.

Only after successful verification does the script replace `PGDATA`.

The process is:

1. detect the active `postgresql*.service`;
2. stop PostgreSQL;
3. move the current `PGDATA` to `.orig`;
4. install the restored `PGDATA`;
5. start PostgreSQL.

For example:

```text
Detected active PostgreSQL service: postgresql.service
Stopping PostgreSQL
Moving current PGDATA to: /var/lib/postgresql/17/main.orig
Installing restored PostgreSQL data
Starting PostgreSQL
PostgreSQL started successfully
Restore completed successfully
```

## Rollback

The original `PGDATA` is not deleted.

The original `/var/lib/postgresql/17/main` directory is moved to `/var/lib/postgresql/17/main.orig`.

If the restored copy fails to start, the script attempts to restore the original directory.

> Do not remove `.orig` until you have confirmed that the restored database is fully operational.

After verification, the old directory can be removed manually:

```bash
rm -rf /var/lib/postgresql/17/main.orig
```

## Configuration Restore

By default, the configuration of the current server is **not modified**.

To restore the configuration files stored in `config.tar.gz`, use:

```bash
psql-restore --backup /opt/pg-backup/postgres_basebackup_2026-09-08_02-53-57.tar \
    --pg-data /var/lib/postgresql/17/main \
    --restore-config
```

The following files are restored:

```bash
postgresql.conf
pg_hba.conf
pg_ident.conf
```

Use this option only if the source server configuration is suitable for the target system.

> This option should only be used when the source and target systems belong to the same OS family. For example, restoring configuration from Debian to Ubuntu is unlikely to cause problems. However, restoring configuration from Debian to Rocky Linux, for example, will likely cause the server to fail to start due to differences in filesystem layout and directory structure.

Pay particular attention to:

* `data_directory`;
* `listen_addresses`;
* `port`;
* `pg_hba.conf`;
* SSL;
* `include` / `include_dir`;
* WAL paths;
* replication settings;
* external files.

`psql-restore` intentionally does not attempt to automatically adapt the configuration to the new environment.

## Restoring to Another Server

A physical backup is intended to restore a compatible PostgreSQL cluster.

The PostgreSQL major version must match the backup. For example, a PostgreSQL 17 backup must be restored to PostgreSQL 17.

If extensions were used on the source server, they must already be installed on the target system in a compatible version.

`psql-restore` does not install PostgreSQL or its extensions and does not perform major-version upgrades or downgrades.

## Disk Space

During the restore, the following may exist simultaneously:

* the original `PGDATA`;
* the extracted backup;
* `.orig` containing the original data;
* the restored `PGDATA`.

Therefore, a significant amount of free disk space is required:

```bash
df -h
```

Check the filesystem where `--pg-data` is located.

## After Restore

Minimum verification:

```bash
# service status:
systemctl status postgresql

# server version:
sudo -u postgres psql -c "SELECT version();"

# databases and encoding:
sudo -u postgres psql -l

# extensions:
sudo -u postgres psql -d <database> -c "\dx"
```

After that, verify the operation of applications using PostgreSQL.

For critical high-availability systems, it is recommended to perform the restore on a separate server first.

# Limitations

The project intentionally remains simple and does not attempt to automate the entire PostgreSQL migration process.

The scripts do not:

* install PostgreSQL;
* install extensions;
* automatically detect `PGDATA`;
* perform major-version migrations;
* automatically adapt the configuration;
* modify firewall or network settings;
* replace a complete disaster recovery procedure.

The purpose of the project is to provide a simple and predictable mechanism for **creating physical PostgreSQL backups and restoring them**.
