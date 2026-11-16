#!/usr/bin/env bash
# Print the evidence report as Markdown on stdout. Every number comes from the
# log tables the lab wrote while it ran; nothing in the report is typed by hand.
#
#   docker compose exec -T mssql bash /lab/scripts/report.sh > docs/evidence/lab-report.md
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# md <database> <tsql returning one text column>
md() {
    local db="$1"
    shift
    "$SQLCMD_BIN" "${SQL_ARGS[@]}" -d "$db" -h -1 -Q "SET NOCOUNT ON; $*" | tr -d '\r' | sed -e 's/[[:space:]]*$//' -e '/^$/d'
}

echo "# TransitOps DBA lab: evidence report"
echo
md master "SELECT N'Generated ' + CONVERT(nvarchar(19), SYSUTCDATETIME(), 120) + N' UTC on SQL Server '
                 + CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(40)) + N' ('
                 + CAST(SERVERPROPERTY('Edition') AS nvarchar(60)) + N', '
                 + ISNULL(CAST(SERVERPROPERTY('ProductUpdateLevel') AS nvarchar(20)), N'RTM') + N').';"
echo
echo "Every figure below was written by the lab's own procedures while it ran."
echo

echo "## Backups"
echo
echo "| Database | Type | Copy only | Started | Duration (ms) | Size (MB) | Compressed (MB) | Verified | Status |"
echo "|---|---|---|---|---:|---:|---:|---|---|"
md DBAdmin "SELECT N'| ' + l.DatabaseName + N' | ' + l.BackupType + N' | ' + CASE WHEN l.IsCopyOnly = 1 THEN N'yes' ELSE N'no' END
                 + N' | ' + CONVERT(nvarchar(19), l.StartedAt, 120)
                 + N' | ' + ISNULL(CAST(DATEDIFF(MILLISECOND, l.StartedAt, l.FinishedAt) AS nvarchar(20)), N'')
                 + N' | ' + ISNULL(CAST(l.SizeMB AS nvarchar(20)), N'')
                 + N' | ' + ISNULL(CAST(l.CompressedSizeMB AS nvarchar(20)), N'')
                 + N' | ' + CASE WHEN l.Verified = 1 THEN N'yes' ELSE N'no' END
                 + N' | ' + l.Status + N' |'
            FROM dba.BackupLog AS l ORDER BY l.BackupLogId;"
echo

echo "## Restore drills"
echo
echo "| Drill | Target | Stop at | Backup files | Restore (s) | RTO target (s) | RPO exposure (s) | RPO target (s) | CHECKDB | Validation | Status |"
echo "|---|---|---|---:|---:|---:|---:|---:|---|---|---|"
md DBAdmin "SELECT N'| ' + d.DrillType + N' | ' + d.TargetDatabase
                 + N' | ' + ISNULL(CONVERT(nvarchar(23), d.StopAt, 121), N'latest')
                 + N' | ' + ISNULL(CAST(d.BackupFilesRestored AS nvarchar(10)), N'')
                 + N' | ' + ISNULL(CAST(d.RestoreSeconds AS nvarchar(10)), N'')
                 + N' | ' + ISNULL(CAST(d.RtoTargetSeconds AS nvarchar(10)), N'')
                 + N' | ' + ISNULL(CAST(d.RpoExposureSeconds AS nvarchar(10)), N'')
                 + N' | ' + ISNULL(CAST(d.RpoTargetSeconds AS nvarchar(10)), N'')
                 + N' | ' + d.CheckDbStatus + N' | ' + d.ValidationStatus + N' | ' + d.Status + N' |'
            FROM dba.RestoreDrillLog AS d ORDER BY d.DrillId;"
echo
md DBAdmin "SELECT N'- ' + d.DrillType + N': ' + ISNULL(d.Notes, N'') FROM dba.RestoreDrillLog AS d ORDER BY d.DrillId;"
echo

echo "## Performance labs"
echo
echo "| Lab | Metric | Before | After | Improvement |"
echo "|---|---|---:|---:|---:|"
md DBAdmin "SELECT N'| ' + s.Lab + N' | ' + s.Metric
                 + N' | ' + CAST(CAST(s.BeforeValue AS bigint) AS nvarchar(20))
                 + N' | ' + CAST(CAST(s.AfterValue AS bigint) AS nvarchar(20))
                 + N' | ' + ISNULL(CAST(s.ImprovementFactor AS nvarchar(20)) + N'x', N'n/a') + N' |'
            FROM lab.vw_PerfSummary AS s
            WHERE s.Metric IN ('logical_reads', 'reader_wait_ms', 'deadlocks')
            ORDER BY s.Lab, s.Metric;"
echo
md DBAdmin "SELECT TOP (1) N'Lab 4 with SQL Server 2022 Parameter Sensitive Plan optimization on: '
                 + CAST(CAST(r.Value AS bigint) AS nvarchar(20)) + N' logical reads for the hub station call.'
            FROM lab.PerfResult AS r
            WHERE r.Lab = 'LAB4_PARAMETER_SNIFFING' AND r.Phase = 'after_psp' AND r.Metric = 'logical_reads'
            ORDER BY r.PerfResultId DESC;"
echo

echo "## Index maintenance"
echo
echo "| Table | Index | Partition | Operation | Pages | Fragmentation before (%) | Fragmentation after (%) |"
echo "|---|---|---:|---|---:|---:|---:|"
md DBAdmin "SELECT N'| ' + l.ObjectName + N' | ' + ISNULL(l.IndexOrStatName, N'')
                 + N' | ' + ISNULL(CAST(l.PartitionNumber AS nvarchar(10)), N'')
                 + N' | ' + l.Operation
                 + N' | ' + ISNULL(CAST(l.PageCount AS nvarchar(20)), N'')
                 + N' | ' + ISNULL(CAST(l.FragmentationBefore AS nvarchar(10)), N'')
                 + N' | ' + ISNULL(CAST(l.FragmentationAfter AS nvarchar(10)), N'') + N' |'
            FROM dba.MaintenanceLog AS l
            WHERE l.Operation IN ('REBUILD', 'REORGANIZE')
            ORDER BY l.MaintenanceLogId;"
echo

echo "## Integrity checks"
echo
echo "| Database | Result | Duration (ms) |"
echo "|---|---|---:|"
md DBAdmin "SELECT N'| ' + l.DatabaseName + N' | ' + l.Status + N' | ' + CAST(DATEDIFF(MILLISECOND, l.StartedAt, l.FinishedAt) AS nvarchar(20)) + N' |'
            FROM dba.IntegrityCheckLog AS l ORDER BY l.IntegrityCheckLogId;"
echo

echo "## Archiving"
echo
echo "| Table | Month archived | Partition | Rows moved by partition switch |"
echo "|---|---|---:|---:|"
md TransitOps "SELECT N'| ' + a.TableName + N' | ' + CONVERT(nvarchar(7), a.MonthStart, 120) + N' | ' + CAST(a.PartitionNumber AS nvarchar(10))
                    + N' | ' + CAST(a.RowsMoved AS nvarchar(20)) + N' |'
               FROM dbo.ArchiveLog AS a ORDER BY a.ArchiveLogId;"
echo

echo "## Schema versions"
echo
echo "| Database | Version | Description | Applied | Script SHA-256 (prefix) |"
echo "|---|---|---|---|---|"
md TransitOps "SELECT N'| TransitOps | ' + v.Version + N' | ' + v.Description + N' | ' + CONVERT(nvarchar(19), v.AppliedAt, 120)
                    + N' | ' + ISNULL(LEFT(v.ScriptSha256, 12), N'') + N' |'
               FROM dbo.SchemaVersion AS v ORDER BY v.Version;"
if [[ "$(scalar master "SELECT COUNT(*) FROM sys.databases WHERE name = N'TransitOps_TEST' AND state_desc = N'ONLINE';")" == "1" ]]; then
    md TransitOps_TEST "SELECT N'| TransitOps_TEST | ' + v.Version + N' | ' + v.Description + N' | ' + CONVERT(nvarchar(19), v.AppliedAt, 120)
                             + N' | ' + ISNULL(LEFT(v.ScriptSha256, 12), N'') + N' |'
                        FROM dbo.SchemaVersion AS v ORDER BY v.Version;"
fi
echo

echo "## Health check (latest run)"
echo
echo "| Severity | Category | Check | Detail |"
echo "|---|---|---|---|"
md DBAdmin "SELECT N'| ' + h.Severity + N' | ' + h.Category + N' | ' + h.CheckName + N' | ' + REPLACE(h.Detail, N'|', N'/') + N' |'
            FROM dba.HealthCheckResult AS h
            WHERE h.RunId = (SELECT TOP (1) x.RunId FROM dba.HealthCheckResult AS x ORDER BY x.HealthCheckResultId DESC)
            ORDER BY CASE h.Severity WHEN 'CRIT' THEN 1 WHEN 'WARN' THEN 2 WHEN 'INFO' THEN 3 ELSE 4 END, h.Category, h.CheckName, h.Detail;"
echo

echo "## Tests"
echo
md DBAdmin "SELECT CAST(SUM(CASE WHEN t.Passed = 1 THEN 1 ELSE 0 END) AS nvarchar(10)) + N' of ' + CAST(COUNT(*) AS nvarchar(10)) + N' assertions passed.'
            FROM dba.TestResult AS t HAVING COUNT(*) > 0;"
echo
echo "| Suite | Result | Test | Detail |"
echo "|---|---|---|---|"
md DBAdmin "SELECT N'| ' + t.Suite + N' | ' + CASE WHEN t.Passed = 1 THEN N'PASS' ELSE N'FAIL' END + N' | ' + t.TestName
                 + N' | ' + REPLACE(ISNULL(t.Detail, N''), N'|', N'/') + N' |'
            FROM dba.TestResult AS t ORDER BY t.TestResultId;"
