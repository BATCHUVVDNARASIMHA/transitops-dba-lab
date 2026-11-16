#!/usr/bin/env bash
# Backup chain, point-in-time recovery from a simulated incident, DR drill, TEST refresh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

D="$SQL_DIR/40_backup_recovery"

log "1. Backup chain: FULL, LOG, DIFF, LOG with workload in between"
run_file "$D/400_backup_chain.sql"

log "2. Incident: an UPDATE without a WHERE clause retires the whole fleet"
run_file "$D/410_incident.sql"

log "3. Point-in-time restore to a side database, stopping before the incident"
run_file "$D/420_pitr_restore.sql"

log "4. Verify the recovery point, repair production from the copy"
run_file "$D/430_pitr_repair.sql"

log "5. DR drill: restore the full chain, CHECKDB, compare with production, measure against the RTO"
run_file "$D/440_dr_drill.sql"

log "6. Refresh TEST from production backups and scrub personal data"
run_file "$D/450_refresh_test.sql"

log "Backup policy compliance"
run_query DBAdmin "SELECT CAST(c.DatabaseName AS nvarchar(16)) AS database_name, c.Tier AS tier, c.PolicyRecoveryModel AS policy_model,
                          CONVERT(char(16), c.LastFull, 120) AS last_full, CONVERT(char(16), c.LastLog, 120) AS last_log,
                          c.RpoMinutes AS rpo_minutes, c.ComplianceStatus AS status
                   FROM dba.vw_BackupCompliance AS c ORDER BY c.Tier, c.DatabaseName;"
