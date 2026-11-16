#!/usr/bin/env bash
# Shared helpers for the lab scripts. Sourced, never executed directly.
# The scripts run inside the SQL Server container, where sqlcmd and the SA
# password (MSSQL_SA_PASSWORD) are already present.

set -euo pipefail

LAB_ROOT="${LAB_ROOT:-/lab}"
# shellcheck disable=SC2034  # used by the scripts that source this file
SQL_DIR="$LAB_ROOT/sqlserver"
BACKUP_ROOT="${BACKUP_ROOT:-/var/opt/mssql/backup}"
AUDIT_DIR="${AUDIT_DIR:-/var/opt/mssql/audit}"

if [[ -x /opt/mssql-tools18/bin/sqlcmd ]]; then
    SQLCMD_BIN=/opt/mssql-tools18/bin/sqlcmd
elif [[ -x /opt/mssql-tools/bin/sqlcmd ]]; then
    SQLCMD_BIN=/opt/mssql-tools/bin/sqlcmd
else
    SQLCMD_BIN="$(command -v sqlcmd || true)"
fi

if [[ -z "$SQLCMD_BIN" ]]; then
    echo "sqlcmd was not found. Run these scripts inside the SQL Server container." >&2
    exit 1
fi

: "${MSSQL_SA_PASSWORD:?MSSQL_SA_PASSWORD is not set}"

# sqlcmd reads the password from SQLCMDPASSWORD, which keeps it out of the process list.
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"

# -C  trust the container's self-signed certificate
# -b  stop at the first error and return a non-zero exit code
# -I  QUOTED_IDENTIFIER ON (required for filtered indexes and XML methods)
# -x  no sqlcmd variable substitution: the scripts are plain T-SQL
# -W  trim trailing spaces, -w wide lines, -s column separator
SQL_ARGS=(-S "${SQL_HOST:-localhost}" -U "${SQL_USER:-sa}" -C -b -I -x -l 30 -W -w 4000 -s "|")

log()  { printf '\n==================================================================\n==> %s\n==================================================================\n' "$*"; }
step() { printf '    -- %s\n' "$*"; }

# run_file <path>            run a script file; every file sets its own database context
run_file() {
    step "$(basename "$1")"
    "$SQLCMD_BIN" "${SQL_ARGS[@]}" -d master -i "$1"
}

# run_dir <directory>        run every .sql file in name order
run_dir() {
    local f
    for f in "$1"/*.sql; do
        run_file "$f"
    done
}

# run_query <database> <tsql>
run_query() {
    local db="$1"
    shift
    "$SQLCMD_BIN" "${SQL_ARGS[@]}" -d "$db" -Q "SET NOCOUNT ON; $*"
}

# scalar <database> <tsql>   print the first non-empty line of the result, trimmed
scalar() {
    local db="$1"
    shift
    "$SQLCMD_BIN" "${SQL_ARGS[@]}" -d "$db" -h -1 -Q "SET NOCOUNT ON; $*" \
        | tr -d '\r' \
        | awk 'NF && !found { gsub(/^[ \t]+|[ \t]+$/, ""); print; found = 1 }'
}

# wait_for_sql [attempts]    block until the instance accepts logins and every database is online
wait_for_sql() {
    local attempts="${1:-90}" i
    for ((i = 1; i <= attempts; i++)); do
        if "$SQLCMD_BIN" "${SQL_ARGS[@]}" -d master -h -1 \
            -Q "SET NOCOUNT ON; IF EXISTS (SELECT 1 FROM sys.databases WHERE state_desc <> N'ONLINE') RAISERROR(N'not ready', 16, 1);" \
            > /dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    echo "SQL Server did not become ready in time." >&2
    return 1
}

agent_is_running() {
    [[ "$(scalar master "SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE program_name LIKE N'SQLAgent%';")" != "0" ]]
}
