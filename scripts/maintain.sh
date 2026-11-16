#!/usr/bin/env bash
# Routine operations: index and statistics maintenance, integrity checks,
# partition archiving, capacity and wait-stat baselines, Agent, health check.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

log "Wait statistics baseline"
run_query DBAdmin "EXEC dba.usp_CaptureWaitStats;"

log "Index maintenance driven by measured fragmentation"
run_query DBAdmin "EXEC dba.usp_IndexMaintenance @DatabaseName = N'TransitOps';"
run_query DBAdmin "SELECT CAST(l.ObjectName AS nvarchar(18)) AS object_name, CAST(l.IndexOrStatName AS nvarchar(28)) AS index_name,
                          l.PartitionNumber AS partition_no, l.Operation AS operation, l.PageCount AS pages,
                          l.FragmentationBefore AS frag_before, l.FragmentationAfter AS frag_after,
                          DATEDIFF(MILLISECOND, l.StartedAt, l.FinishedAt) AS duration_ms, l.ErrorNumber AS error
                   FROM dba.MaintenanceLog AS l WHERE l.Operation IN ('REBUILD', 'REORGANIZE') ORDER BY l.MaintenanceLogId;"

log "Statistics maintenance driven by the modification counter"
run_query DBAdmin "EXEC dba.usp_UpdateStatistics @DatabaseName = N'TransitOps';"

log "Integrity checks (DBCC CHECKDB) on every policy database"
run_query DBAdmin "EXEC dba.usp_IntegrityCheck;"
run_query DBAdmin "SELECT CAST(l.DatabaseName AS nvarchar(18)) AS database_name, l.Status AS status,
                          DATEDIFF(MILLISECOND, l.StartedAt, l.FinishedAt) AS duration_ms,
                          CONVERT(char(19), l.LastGoodCheckDb, 120) AS last_good_checkdb
                   FROM dba.IntegrityCheckLog AS l ORDER BY l.IntegrityCheckLogId;"

log "Archiving: sliding partition window on fare.Tap"
run_file "$SQL_DIR/70_operations/700_sliding_window.sql"

log "Capacity snapshot"
run_query DBAdmin "EXEC dba.usp_CaptureDatabaseSize;"

log "What the instance waited on during maintenance"
run_query DBAdmin "EXEC dba.usp_CaptureWaitStats; EXEC dba.usp_WaitStatsDelta @Top = 8;"

log "History purge"
run_query DBAdmin "EXEC dba.usp_PurgeHistory @RetentionDays = 30, @PurgeBackupFiles = 1;"

log "SQL Server Agent"
run_query msdb "SELECT CAST(j.name AS nvarchar(42)) AS job_name, j.enabled AS enabled FROM dbo.sysjobs AS j WHERE j.name LIKE N'DBA - %' ORDER BY j.name;"
if agent_is_running; then
    run_file "$SQL_DIR/70_operations/710_run_agent_job.sql"
else
    step "SQL Server Agent is not running on this instance; skipping the job execution check"
fi

log "Log backup after maintenance"
run_query DBAdmin "EXEC dba.usp_BackupDatabase @DatabaseName = N'TransitOps', @BackupType = 'LOG', @Description = N'Log backup after maintenance';"

log "Health check"
run_query DBAdmin "EXEC dba.usp_HealthCheck;"
