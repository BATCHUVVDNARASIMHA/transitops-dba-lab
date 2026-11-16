#!/usr/bin/env bash
# Build the lab: instance baseline, DBAdmin toolkit, TransitOps database, security.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

wait_for_sql
mkdir -p "$BACKUP_ROOT" "$AUDIT_DIR"

log "Instance configuration baseline"
run_dir "$SQL_DIR/00_instance"

log "DBAdmin: the DBA toolkit database"
run_dir "$SQL_DIR/10_dbadmin"
run_query DBAdmin "EXEC dba.usp_SetConfig @Name = N'BackupRoot', @Value = N'$BACKUP_ROOT';
                   EXEC dba.usp_SetConfig @Name = N'AuditPath',  @Value = N'$AUDIT_DIR';"

log "TransitOps: database, schema and synthetic data (about a minute)"
run_dir "$SQL_DIR/20_transitops"

log "Security: logins, roles, masking, row-level security, audit"
run_dir "$SQL_DIR/30_security"

log "Deployment complete"
run_query master "SELECT CAST(d.name AS nvarchar(20)) AS database_name, CAST(d.recovery_model_desc AS nvarchar(12)) AS recovery_model,
                         CAST(SUM(mf.size) / 128 AS int) AS allocated_mb
                  FROM sys.databases AS d JOIN sys.master_files AS mf ON mf.database_id = d.database_id
                  WHERE d.name IN (N'TransitOps', N'DBAdmin')
                  GROUP BY d.name, d.recovery_model_desc ORDER BY d.name;"
