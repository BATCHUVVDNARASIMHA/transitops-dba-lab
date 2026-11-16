#!/usr/bin/env bash
# Change management: promote versioned migrations through TEST to production.
#
#   1. apply pending migrations to TransitOps_TEST and validate
#   2. rehearse the rollback of the newest migration in TEST, then reapply it
#   3. take a COPY_ONLY full backup of production (a restore point that leaves
#      the differential base and the log chain untouched)
#   4. apply the same files to TransitOps and validate
#
# Each applied file is recorded in dbo.SchemaVersion with its SHA-256. If a file
# changes after it was applied, the run stops: applied migrations are immutable.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

MIGRATIONS="$SQL_DIR/60_change_management/migrations"
ROLLBACKS="$SQL_DIR/60_change_management/rollback"
VALIDATE="$SQL_DIR/60_change_management/validate.sql"

PROD_DB="TransitOps"
TEST_DB="TransitOps_TEST"

run_in() {   # run_in <database> <file>
    step "$1: $(basename "$2")"
    "$SQLCMD_BIN" "${SQL_ARGS[@]}" -d "$1" -i "$2"
}

apply_pending() {   # apply_pending <database>
    local db="$1" file base version sha recorded
    for file in "$MIGRATIONS"/V*.sql; do
        base="$(basename "$file")"
        version="${base%%__*}"
        sha="$(sha256sum "$file" | awk '{ print $1 }')"
        recorded="$(scalar "$db" "SELECT ISNULL((SELECT v.ScriptSha256 FROM dbo.SchemaVersion AS v WHERE v.Version = '$version'), 'none');")"

        if [[ "$recorded" == "none" ]]; then
            run_in "$db" "$file"
            run_query "$db" "EXEC dbo.usp_RegisterMigration @Version = '$version', @ScriptName = N'$base', @ScriptSha256 = '$sha';"
        elif [[ "$recorded" != "$sha" ]]; then
            echo "DRIFT: $base was modified after it was applied to $db. Write a new migration instead." >&2
            exit 1
        else
            step "$db: $version already applied"
        fi
    done
}

if [[ "$(scalar master "SELECT COUNT(*) FROM sys.databases WHERE name = N'$TEST_DB' AND state_desc = N'ONLINE';")" != "1" ]]; then
    echo "$TEST_DB does not exist. Run the drill step first: it refreshes TEST from production backups." >&2
    exit 1
fi

log "1. Apply pending migrations to $TEST_DB"
apply_pending "$TEST_DB"
run_in "$TEST_DB" "$VALIDATE"

log "2. Rollback rehearsal in $TEST_DB"
newest="$(scalar "$TEST_DB" "SELECT MAX(v.Version) FROM dbo.SchemaVersion AS v;")"
rollback_file="$(find "$ROLLBACKS" -maxdepth 1 -name "R${newest#V}__*.sql" | head -n 1)"
if [[ -z "$rollback_file" ]]; then
    echo "No rollback script for $newest. A migration without a rollback is not ready for production." >&2
    exit 1
fi
run_in "$TEST_DB" "$rollback_file"
run_query "$TEST_DB" "EXEC dbo.usp_UnregisterMigration @Version = '$newest';"
step "$TEST_DB is back at $(scalar "$TEST_DB" "SELECT MAX(v.Version) FROM dbo.SchemaVersion AS v;"); reapplying $newest"
apply_pending "$TEST_DB"
run_in "$TEST_DB" "$VALIDATE"

log "3. Pre-deployment COPY_ONLY backup of $PROD_DB"
run_query DBAdmin "EXEC dba.usp_BackupDatabase @DatabaseName = N'$PROD_DB', @BackupType = 'FULL', @CopyOnly = 1, @Description = N'Pre-deployment restore point';"

log "4. Apply the same migrations to $PROD_DB"
apply_pending "$PROD_DB"
run_in "$PROD_DB" "$VALIDATE"

log "Change management complete"
