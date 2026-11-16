#!/usr/bin/env bash
# RMAN backup and restore validation for the Oracle companion lab.
# Runs inside the database container as the oracle OS user.
#
#   1. put the database in ARCHIVELOG mode (required for online backups and
#      point-in-time recovery; the SQL Server equivalent is FULL recovery)
#   2. level 0 and level 1 incremental backups with archived logs
#   3. RESTORE ... VALIDATE: read every backup piece needed for a restore and
#      check it, without writing a single datafile
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/opt/oracle/oradata/backup}"
mkdir -p "$BACKUP_DIR"

log_mode="$(sqlplus -s / as sysdba <<'SQL' | tr -d '[:space:]'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT log_mode FROM v$database;
EXIT
SQL
)"

if [[ "$log_mode" != "ARCHIVELOG" ]]; then
    echo "Enabling ARCHIVELOG mode (short restart)"
    sqlplus -s / as sysdba <<'SQL'
WHENEVER SQLERROR EXIT FAILURE
SHUTDOWN IMMEDIATE
STARTUP MOUNT
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;
WHENEVER SQLERROR CONTINUE
ALTER PLUGGABLE DATABASE ALL OPEN;
EXIT
SQL
fi

rman target / <<RMAN
CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF 7 DAYS;
CONFIGURE CONTROLFILE AUTOBACKUP ON;
CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE DISK TO '${BACKUP_DIR}/cf_%F';
CONFIGURE CHANNEL DEVICE TYPE DISK FORMAT '${BACKUP_DIR}/%U';
CONFIGURE DEVICE TYPE DISK BACKUP TYPE TO COMPRESSED BACKUPSET;

BACKUP INCREMENTAL LEVEL 0 TAG 'LEVEL0' DATABASE PLUS ARCHIVELOG;
BACKUP INCREMENTAL LEVEL 1 TAG 'LEVEL1' DATABASE PLUS ARCHIVELOG;

RESTORE DATABASE VALIDATE;
RESTORE ARCHIVELOG ALL VALIDATE;

REPORT NEED BACKUP;
CROSSCHECK BACKUP;
DELETE NOPROMPT OBSOLETE;
LIST BACKUP SUMMARY;
EXIT;
RMAN
