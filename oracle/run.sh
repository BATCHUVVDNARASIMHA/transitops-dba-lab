#!/usr/bin/env bash
# Run the Oracle companion lab inside the Oracle Database Free container.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${ORACLE_PWD:?ORACLE_PWD is not set}"

# Connect as SYSTEM to the pluggable database. Flashback is not available to SYS,
# and day-to-day administration should not be done as SYS anyway.
CONNECT="system/\"${ORACLE_PWD}\"@//localhost:1521/FREEPDB1"

run_sql() {
    printf '\n==> %s\n' "$1"
    sqlplus -s -L "$CONNECT" @"$HERE/sql/$1" "${2:-unused}"
}

run_sql 01_schema.sql
run_sql 02_security.sql "$ORACLE_PWD"
run_sql 03_incident_flashback.sql
run_sql 04_tuning.sql

printf '\n==> RMAN backup and restore validation\n'
bash "$HERE/rman/backup_and_validate.sh"

# Enabling ARCHIVELOG mode restarts the instance. Wait until the pluggable
# database is registered with the listener again before the last script.
for _ in $(seq 1 60); do
    if echo "EXIT" | sqlplus -s -L "$CONNECT" > /dev/null 2>&1; then
        break
    fi
    sleep 2
done

run_sql 05_monitoring.sql
