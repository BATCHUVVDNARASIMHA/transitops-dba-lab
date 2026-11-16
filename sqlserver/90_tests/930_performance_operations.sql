/*
    930_performance_operations.sql
    Assertions on the performance labs, maintenance, archiving, jobs and change management.
*/
SET NOCOUNT ON;
USE DBAdmin;
GO

DECLARE @ok bit, @detail nvarchar(1000), @n bigint, @m bigint, @Lab varchar(40), @Title nvarchar(200),
        @Before decimal(18,2), @After decimal(18,2);

-- ---------------------------------------------------------------- labs 1 to 4: logical reads must drop at least five-fold
DECLARE Labs CURSOR LOCAL FAST_FORWARD FOR
    SELECT v.Lab, v.Title
    FROM (VALUES ('LAB1_MISSING_INDEX',       N'Lab 1: covering index cut logical reads at least 5x'),
                 ('LAB2_IMPLICIT_CONVERSION', N'Lab 2: matching the parameter type cut logical reads at least 5x'),
                 ('LAB3_SARGABILITY',         N'Lab 3: sargable date predicate cut logical reads at least 5x'),
                 ('LAB4_PARAMETER_SNIFFING',  N'Lab 4: per-call compilation cut logical reads at least 5x')) AS v (Lab, Title);

OPEN Labs;
FETCH NEXT FROM Labs INTO @Lab, @Title;

WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @Before = NULL, @After = NULL;

    SELECT @Before = s.BeforeValue, @After = s.AfterValue
    FROM lab.vw_PerfSummary AS s
    WHERE s.Lab = @Lab AND s.Metric = 'logical_reads';

    SELECT @ok = CASE WHEN @After > 0 AND @Before >= 5 * @After THEN 1 ELSE 0 END,
           @detail = ISNULL(CAST(CAST(@Before AS bigint) AS nvarchar(20)), N'?') + N' reads before, '
                   + ISNULL(CAST(CAST(@After AS bigint) AS nvarchar(20)), N'?') + N' after';

    EXEC dba.usp_Assert 'performance', @Title, @ok, @detail;

    FETCH NEXT FROM Labs INTO @Lab, @Title;
END;

CLOSE Labs;
DEALLOCATE Labs;

-- ---------------------------------------------------------------- lab 5: blocking
SELECT @Before = NULL, @After = NULL;
SELECT @Before = s.BeforeValue, @After = s.AfterValue
FROM lab.vw_PerfSummary AS s
WHERE s.Lab = 'LAB5_BLOCKING' AND s.Metric = 'reader_wait_ms';

SELECT @ok = CASE WHEN @Before >= 3000 AND @After < 1500 THEN 1 ELSE 0 END,
       @detail = N'reader waited ' + ISNULL(CAST(CAST(@Before AS bigint) AS nvarchar(20)), N'?') + N' ms before, '
               + ISNULL(CAST(CAST(@After AS bigint) AS nvarchar(20)), N'?') + N' ms after';
EXEC dba.usp_Assert 'performance', N'Lab 5: reader no longer waits behind the writer with READ_COMMITTED_SNAPSHOT', @ok, @detail;

SELECT @n = COUNT(*) FROM dba.BlockingSnapshot AS b WHERE b.DatabaseName = N'TransitOps';
SELECT @ok = CASE WHEN @n >= 1 THEN 1 ELSE 0 END, @detail = CAST(@n AS nvarchar(20)) + N' blocked session(s) captured';
EXEC dba.usp_Assert 'performance', N'Lab 5: the blocking chain was captured while it was happening', @ok, @detail;

SELECT @ok = CAST(d.is_read_committed_snapshot_on AS bit), @detail = NULL
FROM sys.databases AS d WHERE d.name = N'TransitOps';
EXEC dba.usp_Assert 'performance', N'READ_COMMITTED_SNAPSHOT is on for TransitOps', @ok, @detail;

-- ---------------------------------------------------------------- lab 6: deadlock
SELECT @Before = NULL, @After = NULL;
SELECT TOP (1) @Before = r.Value FROM lab.PerfResult AS r WHERE r.Lab = 'LAB6_DEADLOCK' AND r.Phase = 'before' AND r.Metric = 'deadlocks' ORDER BY r.PerfResultId DESC;
SELECT TOP (1) @After  = r.Value FROM lab.PerfResult AS r WHERE r.Lab = 'LAB6_DEADLOCK' AND r.Phase = 'after'  AND r.Metric = 'deadlocks' ORDER BY r.PerfResultId DESC;

SELECT @ok = CASE WHEN @Before >= 1 AND @After = 0 THEN 1 ELSE 0 END,
       @detail = ISNULL(CAST(CAST(@Before AS int) AS nvarchar(10)), N'?') + N' deadlock(s) with opposite lock order, '
               + ISNULL(CAST(CAST(@After AS int) AS nvarchar(10)), N'?') + N' with consistent lock order';
EXEC dba.usp_Assert 'performance', N'Lab 6: deadlock captured, then eliminated by consistent lock ordering', @ok, @detail;

-- ---------------------------------------------------------------- maintenance
SELECT @n = COUNT(*), @m = SUM(CASE WHEN l.ErrorNumber IS NOT NULL THEN 1 ELSE 0 END)
FROM dba.MaintenanceLog AS l
WHERE l.Operation IN ('REBUILD', 'REORGANIZE');
SELECT @ok = CASE WHEN @n >= 1 AND @m = 0 THEN 1 ELSE 0 END,
       @detail = CAST(@n AS nvarchar(20)) + N' index operation(s), ' + ISNULL(CAST(@m AS nvarchar(20)), N'0') + N' error(s)';
EXEC dba.usp_Assert 'operations', N'Index maintenance ran on fragmented indexes without errors', @ok, @detail;

SELECT @n = COUNT(*), @m = SUM(CASE WHEN l.FragmentationAfter < l.FragmentationBefore THEN 1 ELSE 0 END)
FROM dba.MaintenanceLog AS l
WHERE l.Operation = 'REBUILD' AND l.ErrorNumber IS NULL;
SELECT @ok = CASE WHEN @n = ISNULL(@m, 0) THEN 1 ELSE 0 END,
       @detail = ISNULL(CAST(@m AS nvarchar(20)), N'0') + N' of ' + CAST(@n AS nvarchar(20)) + N' rebuilds reduced fragmentation';
EXEC dba.usp_Assert 'operations', N'Every rebuild reduced fragmentation', @ok, @detail;

SELECT @n = COUNT(*), @m = SUM(CASE WHEN l.Status = 'CLEAN' THEN 1 ELSE 0 END)
FROM dba.IntegrityCheckLog AS l;
SELECT @ok = CASE WHEN @n >= 5 AND @n = @m THEN 1 ELSE 0 END,
       @detail = ISNULL(CAST(@m AS nvarchar(20)), N'0') + N' of ' + CAST(@n AS nvarchar(20)) + N' CHECKDB runs clean';
EXEC dba.usp_Assert 'operations', N'DBCC CHECKDB is clean on every policy database', @ok, @detail;

-- ---------------------------------------------------------------- archiving
SELECT @n = (SELECT COUNT_BIG(*) FROM TransitOps.fare.Tap AS t WHERE t.TapDateTime >= '2026-05-01T00:00:00' AND t.TapDateTime < '2026-06-01T00:00:00'),
       @m = (SELECT COUNT_BIG(*) FROM TransitOps.fare.TapArchive);
SELECT @ok = CASE WHEN @n = 0 AND @m > 0 AND @m = (SELECT SUM(a.RowsMoved) FROM TransitOps.dbo.ArchiveLog AS a) THEN 1 ELSE 0 END,
       @detail = CAST(@m AS nvarchar(20)) + N' rows in the archive, ' + CAST(@n AS nvarchar(20)) + N' May rows left in the live table';
EXEC dba.usp_Assert 'operations', N'May 2026 was archived by partition switch with no rows lost', @ok, @detail;

SELECT @n = COUNT(*)
FROM TransitOps.sys.partition_range_values AS prv
JOIN TransitOps.sys.partition_functions AS f ON f.function_id = prv.function_id
WHERE f.name = N'pf_TapMonthly' AND CAST(prv.value AS datetime2(0)) = '2027-01-01T00:00:00';
SELECT @ok = CASE WHEN @n = 1 THEN 1 ELSE 0 END, @detail = NULL;
EXEC dba.usp_Assert 'operations', N'Partition for January 2027 was added ahead of time', @ok, @detail;

-- ---------------------------------------------------------------- jobs
SELECT @n = COUNT(*)
FROM msdb.dbo.sysjobs AS j
WHERE j.name LIKE N'DBA - %'
  AND EXISTS (SELECT 1 FROM msdb.dbo.sysjobschedules AS js WHERE js.job_id = j.job_id);
SELECT @ok = CASE WHEN @n = 9 THEN 1 ELSE 0 END, @detail = CAST(@n AS nvarchar(20)) + N' scheduled job(s)';
EXEC dba.usp_Assert 'operations', N'All nine DBA Agent jobs are deployed with schedules', @ok, @detail;

IF EXISTS (SELECT 1 FROM sys.dm_exec_sessions AS s WHERE s.program_name LIKE N'SQLAgent%')
BEGIN
    SELECT @n = COUNT(*)
    FROM msdb.dbo.sysjobhistory AS h
    JOIN msdb.dbo.sysjobs AS j ON j.job_id = h.job_id
    WHERE j.name = N'DBA - Health Check' AND h.step_id = 0 AND h.run_status = 1;
    SELECT @ok = CASE WHEN @n >= 1 THEN 1 ELSE 0 END, @detail = CAST(@n AS nvarchar(20)) + N' successful run(s) in job history';
END
ELSE
    SELECT @ok = 1, @detail = N'skipped: SQL Server Agent is not running on this instance';
EXEC dba.usp_Assert 'operations', N'SQL Server Agent executed the health check job', @ok, @detail;

-- ---------------------------------------------------------------- change management
SELECT @n = COUNT(*)
FROM TransitOps.dbo.SchemaVersion AS p
JOIN TransitOps_TEST.dbo.SchemaVersion AS t
  ON t.Version = p.Version AND t.ScriptSha256 = p.ScriptSha256
WHERE p.Version IN ('V002', 'V003');
SELECT @ok = CASE WHEN @n = 2 THEN 1 ELSE 0 END, @detail = CAST(@n AS nvarchar(20)) + N' of 2 migrations identical in TEST and production';
EXEC dba.usp_Assert 'change', N'Migrations V002 and V003 applied to TEST and production from identical scripts', @ok, @detail;

SELECT @ok = CASE WHEN COL_LENGTH(N'TransitOps.ref.Stop', N'IsAccessible') IS NOT NULL
                       AND OBJECT_ID(N'TransitOps.rpt.vw_RouteDelaySummary', N'V') IS NOT NULL THEN 1 ELSE 0 END,
       @detail = NULL;
EXEC dba.usp_Assert 'change', N'Production schema contains the migrated objects', @ok, @detail;
GO

-- ---------------------------------------------------------------- health check
EXEC dba.usp_HealthCheck @Quiet = 1;
GO

DECLARE @ok bit, @detail nvarchar(1000), @n int;

SELECT @n = COUNT(*),
       @detail = ISNULL(STRING_AGG(CAST(h.CheckName + N': ' + h.Detail AS nvarchar(max)), N' | '), N'no critical findings')
FROM dba.HealthCheckResult AS h
WHERE h.RunId = (SELECT TOP (1) x.RunId FROM dba.HealthCheckResult AS x ORDER BY x.HealthCheckResultId DESC)
  AND h.Severity = 'CRIT';
SELECT @ok = CASE WHEN @n = 0 THEN 1 ELSE 0 END, @detail = LEFT(@detail, 900);
EXEC dba.usp_Assert 'operations', N'Health check reports no critical findings', @ok, @detail;
GO
