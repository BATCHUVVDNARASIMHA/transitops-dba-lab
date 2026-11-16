#!/usr/bin/env bash
# Remove everything the lab created, including backup and audit files.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

wait_for_sql
log "Reset"
run_file "$SQL_DIR/99_reset/990_reset.sql"

if [[ -d "$BACKUP_ROOT" ]]; then
    find "$BACKUP_ROOT" -mindepth 1 -delete
fi
if [[ -d "$AUDIT_DIR" ]]; then
    find "$AUDIT_DIR" -mindepth 1 -delete
fi
step "backup and audit folders emptied"
