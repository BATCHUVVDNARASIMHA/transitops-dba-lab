/*
    150_monitoring.sql

    Monitoring procedures.

      usp_HealthCheck          one pass over availability, recoverability, integrity,
                               capacity, configuration, security and concurrency
      usp_CaptureBlocking      snapshot of blocked sessions and who is blocking them
      usp_GetDeadlocks         deadlock reports from the DBA_Concurrency Extended Events session
      usp_CaptureWaitStats     wait statistics snapshot; usp_WaitStatsDelta compares the last two
      usp_CaptureDatabaseSize  file size and space used, for growth trending

    Collation note: catalog and DMV text columns do not always share the database
    collation, so anything compared or concatenated with them is pinned with
    COLLATE DATABASE_DEFAULT. Without it these procedures fail on any instance whose
    collation differs from the catalog's.
*/
SET NOCOUNT ON;
USE DBAdmin;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dba.usp_HealthCheck
    @Quiet bit = 0     -- 1 = store results only (used by the Agent job)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RunId      uniqueidentifier = NEWID(),
            @Now        datetime = GETDATE(),
            @Db         sysname,
            @Sql        nvarchar(max),
            @Cores      int,
            @Count      int,
            @RingBuffer xml;

    CREATE TABLE #Result (
        Category   varchar(30)    COLLATE DATABASE_DEFAULT NOT NULL,
        CheckName  varchar(80)    COLLATE DATABASE_DEFAULT NOT NULL,
        Severity   varchar(5)     COLLATE DATABASE_DEFAULT NOT NULL,
        Detail     nvarchar(1000) COLLATE DATABASE_DEFAULT NOT NULL
    );

    -- ================================================================ availability
    INSERT #Result (Category, CheckName, Severity, Detail)
    SELECT 'Availability', 'Database state', 'CRIT',
           d.name + N' is ' + d.state_desc COLLATE DATABASE_DEFAULT
    FROM sys.databases AS d
    WHERE d.state_desc <> N'ONLINE';

    IF @@ROWCOUNT = 0
        INSERT #Result VALUES ('Availability', 'Database state', 'OK', N'All databases are ONLINE.');

    -- ================================================================ recoverability
    INSERT #Result (Category, CheckName, Severity, Detail)
    SELECT 'Recoverability', 'Backup policy compliance',
           CASE WHEN c.ComplianceStatus IN ('COMPLIANT', 'EXEMPT') THEN 'OK'
                WHEN c.ComplianceStatus = 'RPO AT RISK' THEN 'WARN'
                ELSE 'CRIT' END,
           c.DatabaseName + N': ' + c.ComplianceStatus
           + CASE WHEN c.LastFull IS NULL THEN N'' ELSE N', last full ' + CONVERT(nvarchar(16), c.LastFull, 120) END
           + CASE WHEN c.LastLog  IS NULL THEN N'' ELSE N', last log '  + CONVERT(nvarchar(16), c.LastLog, 120) END
    FROM dba.vw_BackupCompliance AS c;

    INSERT #Result (Category, CheckName, Severity, Detail)
    SELECT 'Recoverability', 'Database without backup policy', 'WARN',
           d.name + N' has no row in dba.BackupPolicy.'
    FROM sys.databases AS d
    WHERE d.name <> N'tempdb'
      AND NOT EXISTS (SELECT 1 FROM dba.BackupPolicy AS p WHERE p.DatabaseName = d.name COLLATE DATABASE_DEFAULT);

    -- ================================================================ integrity
    INSERT #Result (Category, CheckName, Severity, Detail)
    SELECT 'Integrity', 'CHECKDB in the last 7 days',
           CASE WHEN x.LastGood >= DATEADD(DAY, -7, @Now) THEN 'OK' ELSE 'WARN' END,
           d.name + N': last clean CHECKDB '
           + CASE WHEN x.LastGood IS NULL OR x.LastGood < '20000101' THEN N'never' ELSE CONVERT(nvarchar(16), x.LastGood, 120) END
    FROM sys.databases AS d
    CROSS APPLY (SELECT CAST(DATABASEPROPERTYEX(d.name, 'LastGoodCheckDbTime') AS datetime) AS LastGood) AS x
    WHERE d.name <> N'tempdb'
      AND d.state_desc = N'ONLINE';

    INSERT #Result (Category, CheckName, Severity, Detail)
    SELECT 'Integrity', 'Page verify', 'WARN',
           d.name + N' uses PAGE_VERIFY ' + d.page_verify_option_desc COLLATE DATABASE_DEFAULT + N' instead of CHECKSUM.'
    FROM sys.databases AS d
    WHERE d.page_verify_option_desc <> N'CHECKSUM';

    IF @@ROWCOUNT = 0
        INSERT #Result VALUES ('Integrity', 'Page verify', 'OK', N'All databases use CHECKSUM page verification.');

    SELECT @Count = COUNT(*) FROM msdb.dbo.suspect_pages;

    INSERT #Result VALUES ('Integrity', 'Suspect pages',
                           CASE WHEN @Count > 0 THEN 'CRIT' ELSE 'OK' END,
                           CAST(@Count AS nvarchar(10)) + N' row(s) in msdb.dbo.suspect_pages.');

    -- ================================================================ database settings
    INSERT #Result (Category, CheckName, Severity, Detail)
    SELECT 'Configuration', 'Auto close or auto shrink', 'WARN',
           d.name + N' has AUTO_CLOSE or AUTO_SHRINK enabled.'
    FROM sys.databases AS d
    WHERE d.is_auto_close_on = 1 OR d.is_auto_shrink_on = 1;

    IF @@ROWCOUNT = 0
        INSERT #Result VALUES ('Configuration', 'Auto close or auto shrink', 'OK', N'No database uses AUTO_CLOSE or AUTO_SHRINK.');

    -- ================================================================ capacity and transaction log
    INSERT #Result (Category, CheckName, Severity, Detail)
    SELECT 'Capacity', 'File growth setting', 'WARN',
           DB_NAME(mf.database_id) + N': file ' + mf.name + N' grows by a percentage. Use a fixed increment.'
    FROM sys.master_files AS mf
    WHERE mf.is_percent_growth = 1
      AND mf.database_id > 4;

    IF @@ROWCOUNT = 0
        INSERT #Result VALUES ('Capacity', 'File growth setting', 'OK', N'All user database files use fixed growth increments.');

    INSERT #Result (Category, CheckName, Severity, Detail)
    SELECT 'Transaction log', 'Virtual log files',
           CASE WHEN v.VlfCount > 1000 THEN 'CRIT' WHEN v.VlfCount > 200 THEN 'WARN' ELSE 'OK' END,
           d.name + N': ' + CAST(v.VlfCount AS nvarchar(10)) + N' VLFs'
    FROM sys.databases AS d
    CROSS APPLY (SELECT COUNT(*) AS VlfCount FROM sys.dm_db_log_info(d.database_id)) AS v
    WHERE d.state_desc = N'ONLINE'
      AND d.database_id > 4;

    CREATE TABLE #LogSpace (
        DatabaseName  sysname COLLATE DATABASE_DEFAULT NOT NULL,
        LogSizeMB     float   NOT NULL,
        LogUsedPct    float   NOT NULL,
        Status        int     NOT NULL
    );

    INSERT #LogSpace (DatabaseName, LogSizeMB, LogUsedPct, Status)
    EXEC (N'DBCC SQLPERF(LOGSPACE) WITH NO_INFOMSGS;');

    INSERT #Result (Category, CheckName, Severity, Detail)
    SELECT 'Transaction log', 'Log space used',
           CASE WHEN ls.LogUsedPct >= 90 THEN 'CRIT' ELSE 'WARN' END,
           ls.DatabaseName + N': log is ' + CAST(CAST(ls.LogUsedPct AS decimal(5,1)) AS nvarchar(10)) + N' percent full ('
           + CAST(CAST(ls.LogSizeMB AS decimal(12,0)) AS nvarchar(20)) + N' MB).'
    FROM #LogSpace AS ls
    WHERE ls.LogUsedPct >= 75;

    IF @@ROWCOUNT = 0
        INSERT #Result VALUES ('Transaction log', 'Log space used', 'OK', N'No transaction log is more than 75 percent full.');

    INSERT #Result (Category, CheckName, Severity, Detail)
    SELECT 'Transaction log', 'Log reuse wait', 'INFO',
           d.name + N': log truncation is waiting on ' + d.log_reuse_wait_desc COLLATE DATABASE_DEFAULT
    FROM sys.databases AS d
    WHERE d.log_reuse_wait_desc IN (N'ACTIVE_TRANSACTION', N'REPLICATION', N'AVAILABILITY_REPLICA', N'DATABASE_MIRRORING', N'LOG_SCAN');

    -- ================================================================ instance configuration
    SELECT @Cores = si.cpu_count FROM sys.dm_os_sys_info AS si;

    INSERT #Result (Category, CheckName, Severity, Detail)
    SELECT 'Configuration', x.CheckName, x.Severity, x.Detail
    FROM (
        SELECT 'Max server memory' AS CheckName,
               CASE WHEN CAST(c.value_in_use AS bigint) >= 2147483647 THEN 'WARN' ELSE 'OK' END AS Severity,
               N'max server memory (MB) = ' + CAST(CAST(c.value_in_use AS bigint) AS nvarchar(20)) AS Detail
        FROM sys.configurations AS c WHERE c.name = N'max server memory (MB)'
        UNION ALL
        SELECT 'Cost threshold for parallelism',
               CASE WHEN CAST(c.value_in_use AS int) <= 5 THEN 'WARN' ELSE 'OK' END,
               N'cost threshold for parallelism = ' + CAST(CAST(c.value_in_use AS int) AS nvarchar(20))
        FROM sys.configurations AS c WHERE c.name = N'cost threshold for parallelism'
        UNION ALL
        SELECT 'Max degree of parallelism',
               CASE WHEN CAST(c.value_in_use AS int) = 0 AND @Cores > 8 THEN 'WARN' ELSE 'OK' END,
               N'max degree of parallelism = ' + CAST(CAST(c.value_in_use AS int) AS nvarchar(20)) + N' on ' + CAST(@Cores AS nvarchar(10)) + N' core(s)'
        FROM sys.configurations AS c WHERE c.name = N'max degree of parallelism'
        UNION ALL
        SELECT 'Backup compression default',
               CASE WHEN CAST(c.value_in_use AS int) = 1 THEN 'OK' ELSE 'WARN' END,
               N'backup compression default = ' + CAST(CAST(c.value_in_use AS int) AS nvarchar(20))
        FROM sys.configurations AS c WHERE c.name = N'backup compression default'
        UNION ALL
        SELECT 'Backup checksum default',
               CASE WHEN CAST(c.value_in_use AS int) = 1 THEN 'OK' ELSE 'WARN' END,
               N'backup checksum default = ' + CAST(CAST(c.value_in_use AS int) AS nvarchar(20))
        FROM sys.configurations AS c WHERE c.name = N'backup checksum default'
        UNION ALL
        SELECT 'Remote admin connections',
               CASE WHEN CAST(c.value_in_use AS int) = 1 THEN 'OK' ELSE 'WARN' END,
               N'remote admin connections = ' + CAST(CAST(c.value_in_use AS int) AS nvarchar(20))
        FROM sys.configurations AS c WHERE c.name = N'remote admin connections'
    ) AS x;

    SELECT @Count = COUNT(*)
    FROM sys.master_files AS mf
    WHERE mf.database_id = 2 AND mf.type = 0;

    INSERT #Result VALUES ('Configuration', 'tempdb data files',
                           CASE WHEN @Count >= CASE WHEN @Cores > 8 THEN 8 ELSE @Cores END THEN 'OK' ELSE 'WARN' END,
                           CAST(@Count AS nvarchar(10)) + N' tempdb data file(s) for ' + CAST(@Cores AS nvarchar(10)) + N' core(s).');

    -- ================================================================ security
    INSERT #Result (Category, CheckName, Severity, Detail)
    SELECT 'Security', 'sa login',
           CASE WHEN sp.is_disabled = 1 THEN 'OK' ELSE 'INFO' END,
           CASE WHEN sp.is_disabled = 1 THEN N'sa is disabled.'
                ELSE N'sa is enabled. Expected in this lab; disable or rename it in production.' END
    FROM sys.server_principals AS sp
    WHERE sp.sid = 0x01;

    INSERT #Result (Category, CheckName, Severity, Detail)
    SELECT 'Security', 'Password policy', 'WARN',
           l.name + N' is not subject to the password policy (CHECK_POLICY = OFF).'
    FROM sys.sql_logins AS l
    WHERE l.is_policy_checked = 0
      AND l.name NOT LIKE N'##%';

    IF @@ROWCOUNT = 0
        INSERT #Result VALUES ('Security', 'Password policy', 'OK', N'Every SQL login enforces the password policy.');

    SELECT @Count = COUNT(*)
    FROM sys.server_role_members AS rm
    JOIN sys.server_principals AS r ON r.principal_id = rm.role_principal_id
    JOIN sys.server_principals AS m ON m.principal_id = rm.member_principal_id
    WHERE r.name = N'sysadmin'
      AND m.is_disabled = 0
      AND m.name NOT LIKE N'NT %'
      AND m.name NOT LIKE N'##%';

    INSERT #Result VALUES ('Security', 'sysadmin members',
                           CASE WHEN @Count > 3 THEN 'WARN' ELSE 'INFO' END,
                           CAST(@Count AS nvarchar(10)) + N' enabled sysadmin login(s). Review against the access list.');

    SELECT @Count = COUNT(*)
    FROM sys.dm_server_audit_status AS a
    WHERE a.status_desc = N'STARTED';

    INSERT #Result VALUES ('Security', 'Server audit',
                           CASE WHEN @Count > 0 THEN 'OK' ELSE 'WARN' END,
                           CAST(@Count AS nvarchar(10)) + N' server audit(s) running.');

    -- ================================================================ concurrency
    INSERT #Result (Category, CheckName, Severity, Detail)
    SELECT 'Concurrency', 'Blocked sessions', 'WARN',
           N'Session ' + CAST(r.session_id AS nvarchar(10)) + N' has been blocked by session '
           + CAST(r.blocking_session_id AS nvarchar(10)) + N' for ' + CAST(r.wait_time / 1000 AS nvarchar(10)) + N' s.'
    FROM sys.dm_exec_requests AS r
    WHERE r.blocking_session_id <> 0
      AND r.wait_time > 30000;

    IF @@ROWCOUNT = 0
        INSERT #Result VALUES ('Concurrency', 'Blocked sessions', 'OK', N'No session has been blocked for more than 30 seconds.');

    INSERT #Result (Category, CheckName, Severity, Detail)
    SELECT 'Concurrency', 'Long open transaction', 'WARN',
           N'Session ' + CAST(st.session_id AS nvarchar(10)) + N' has had a transaction open for '
           + CAST(DATEDIFF(MINUTE, tx.transaction_begin_time, @Now) AS nvarchar(10)) + N' minute(s).'
    FROM sys.dm_tran_session_transactions AS st
    JOIN sys.dm_tran_active_transactions AS tx ON tx.transaction_id = st.transaction_id
    WHERE st.is_user_transaction = 1
      AND tx.transaction_begin_time < DATEADD(MINUTE, -15, @Now);

    IF @@ROWCOUNT = 0
        INSERT #Result VALUES ('Concurrency', 'Long open transaction', 'OK', N'No user transaction has been open for more than 15 minutes.');

    SELECT @RingBuffer = CAST(t.target_data AS xml)
    FROM sys.dm_xe_sessions AS s
    JOIN sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
    WHERE s.name = N'DBA_Concurrency'
      AND t.target_name = N'ring_buffer';

    IF @RingBuffer IS NULL
        INSERT #Result VALUES ('Concurrency', 'Deadlock capture', 'WARN', N'The DBA_Concurrency Extended Events session is not running.');
    ELSE
    BEGIN
        SET @Count = @RingBuffer.value('count(/RingBufferTarget/event[@name="xml_deadlock_report"])', 'int');

        INSERT #Result VALUES ('Concurrency', 'Deadlock capture',
                               CASE WHEN @Count > 0 THEN 'INFO' ELSE 'OK' END,
                               CAST(@Count AS nvarchar(10)) + N' deadlock(s) in the DBA_Concurrency session buffer. See dba.usp_GetDeadlocks.');
    END;

    -- ================================================================ jobs
    INSERT #Result (Category, CheckName, Severity, Detail)
    SELECT 'Jobs', 'Agent job failures in 24 hours', 'WARN',
           j.name + N' failed at ' + CONVERT(nvarchar(16), msdb.dbo.agent_datetime(h.run_date, h.run_time), 120)
    FROM msdb.dbo.sysjobhistory AS h
    JOIN msdb.dbo.sysjobs AS j ON j.job_id = h.job_id
    WHERE h.step_id = 0
      AND h.run_status = 0
      AND msdb.dbo.agent_datetime(h.run_date, h.run_time) >= DATEADD(DAY, -1, @Now);

    IF @@ROWCOUNT = 0
        INSERT #Result VALUES ('Jobs', 'Agent job failures in 24 hours', 'OK', N'No Agent job has failed in the last 24 hours.');

    -- ================================================================ per-database checks
    DECLARE UserDatabases CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state_desc = N'ONLINE'
          AND d.user_access_desc = N'MULTI_USER'
        ORDER BY d.name;

    OPEN UserDatabases;
    FETCH NEXT FROM UserDatabases INTO @Db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Sql = N'USE ' + QUOTENAME(@Db) + N';

            SELECT ''Integrity'', ''Untrusted constraint'', ''WARN'',
                   DB_NAME() + N'': '' + OBJECT_SCHEMA_NAME(x.parent_object_id) + N''.'' + OBJECT_NAME(x.parent_object_id)
                   + N'' constraint '' + x.name COLLATE DATABASE_DEFAULT + N'' is not trusted.''
            FROM (SELECT fk.name, fk.parent_object_id FROM sys.foreign_keys AS fk WHERE fk.is_not_trusted = 1 AND fk.is_disabled = 0
                  UNION ALL
                  SELECT ck.name, ck.parent_object_id FROM sys.check_constraints AS ck WHERE ck.is_not_trusted = 1 AND ck.is_disabled = 0) AS x;

            SELECT ''Security'', ''Orphaned user'', ''WARN'',
                   DB_NAME() + N'': user '' + dp.name COLLATE DATABASE_DEFAULT + N'' has no matching login.''
            FROM sys.database_principals AS dp
            LEFT JOIN sys.server_principals AS sp ON sp.sid = dp.sid
            WHERE dp.type IN (''S'', ''U'', ''G'')
              AND dp.authentication_type_desc = N''INSTANCE''
              AND dp.principal_id > 4
              AND sp.sid IS NULL;

            SELECT ''Capacity'', ''Data file usage'', ''INFO'',
                   DB_NAME() + N'': '' + f.name COLLATE DATABASE_DEFAULT + N'' ''
                   + CAST(CAST(CAST(FILEPROPERTY(f.name, ''SpaceUsed'') AS int) / 128.0 AS decimal(12,0)) AS nvarchar(20)) + N'' MB used of ''
                   + CAST(CAST(f.size / 128.0 AS decimal(12,0)) AS nvarchar(20)) + N'' MB allocated''
            FROM sys.database_files AS f
            WHERE f.type = 0;';

        BEGIN TRY
            INSERT #Result (Category, CheckName, Severity, Detail)
            EXEC sys.sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            INSERT #Result VALUES ('Availability', 'Per-database checks', 'WARN', @Db + N': ' + LEFT(ERROR_MESSAGE(), 800));
        END CATCH;

        FETCH NEXT FROM UserDatabases INTO @Db;
    END;

    CLOSE UserDatabases;
    DEALLOCATE UserDatabases;

    -- ================================================================ persist and report
    INSERT dba.HealthCheckResult (RunId, CheckedAt, Category, CheckName, Severity, Detail)
    SELECT @RunId, @Now, r.Category, r.CheckName, r.Severity, r.Detail
    FROM #Result AS r;

    IF @Quiet = 0
        SELECT r.Severity, r.Category, r.CheckName, CAST(r.Detail AS nvarchar(200)) AS Detail
        FROM #Result AS r
        ORDER BY CASE r.Severity WHEN 'CRIT' THEN 1 WHEN 'WARN' THEN 2 WHEN 'INFO' THEN 3 ELSE 4 END,
                 r.Category, r.CheckName, r.Detail;
END;
GO

-- ---------------------------------------------------------------------------
-- Blocking snapshot. Run it while users are complaining: afterwards the evidence is gone.
-- The head blocker is the session that blocks others without being blocked itself.
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dba.usp_CaptureBlocking
    @MinWaitMs int = 5000
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now datetime2(3) = SYSDATETIME();

    INSERT dba.BlockingSnapshot (CapturedAt, DatabaseName, BlockedSessionId, BlockingSessionId, IsHeadBlocker,
                                 WaitType, WaitTimeMs, WaitResource, BlockedLogin, BlockedProgram, BlockedStatement,
                                 BlockingLogin, BlockingProgram, BlockingStatus, BlockingOpenTranCount, BlockingLastBatch)
    SELECT @Now,
           DB_NAME(r.database_id),
           r.session_id,
           r.blocking_session_id,
           CASE WHEN EXISTS (SELECT 1
                             FROM sys.dm_exec_requests AS r2
                             WHERE r2.session_id = r.blocking_session_id
                               AND r2.blocking_session_id <> 0) THEN 0 ELSE 1 END,
           r.wait_type,
           r.wait_time,
           r.wait_resource,
           s.login_name,
           LEFT(s.program_name, 128),
           CAST(SUBSTRING(t.text,
                          (r.statement_start_offset / 2) + 1,
                          ((CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(t.text) ELSE r.statement_end_offset END
                            - r.statement_start_offset) / 2) + 1) AS nvarchar(4000)),
           bs.login_name,
           LEFT(bs.program_name, 128),
           bs.status,
           bs.open_transaction_count,
           CAST(ib.event_info AS nvarchar(4000))
    FROM sys.dm_exec_requests AS r
    JOIN sys.dm_exec_sessions AS s ON s.session_id = r.session_id
    LEFT JOIN sys.dm_exec_sessions AS bs ON bs.session_id = r.blocking_session_id
    OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
    OUTER APPLY sys.dm_exec_input_buffer(r.blocking_session_id, NULL) AS ib
    WHERE r.blocking_session_id > 0
      AND r.wait_time >= @MinWaitMs;

    SELECT b.CapturedAt, b.DatabaseName, b.BlockedSessionId, b.BlockingSessionId, b.IsHeadBlocker,
           b.WaitType, b.WaitTimeMs,
           CAST(b.WaitResource AS nvarchar(60))       AS WaitResource,
           CAST(b.BlockedStatement AS nvarchar(120))  AS BlockedStatement,
           b.BlockingStatus, b.BlockingOpenTranCount,
           CAST(b.BlockingLastBatch AS nvarchar(120)) AS BlockingLastBatch
    FROM dba.BlockingSnapshot AS b
    WHERE b.CapturedAt = @Now
    ORDER BY b.IsHeadBlocker DESC, b.WaitTimeMs DESC;
END;
GO

-- ---------------------------------------------------------------------------
-- Deadlocks captured by the DBA_Concurrency session: one row per process involved.
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dba.usp_GetDeadlocks
    @CountOnly bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RingBuffer xml;

    SELECT @RingBuffer = CAST(t.target_data AS xml)
    FROM sys.dm_xe_sessions AS s
    JOIN sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
    WHERE s.name = N'DBA_Concurrency'
      AND t.target_name = N'ring_buffer';

    IF @RingBuffer IS NULL
    BEGIN
        RAISERROR(N'The DBA_Concurrency Extended Events session is not running.', 16, 1);
        RETURN -1;
    END;

    IF @CountOnly = 1
    BEGIN
        DECLARE @DeadlockCount int = @RingBuffer.value('count(/RingBufferTarget/event[@name="xml_deadlock_report"])', 'int');
        RETURN @DeadlockCount;
    END;

    SELECT d.EventTimeUtc,
           p.ProcessNode.value('@spid', 'int')                                    AS SessionId,
           CASE WHEN p.ProcessNode.value('@id', 'varchar(60)') = d.VictimProcessId THEN 1 ELSE 0 END AS IsVictim,
           p.ProcessNode.value('@loginname', 'nvarchar(128)')                     AS LoginName,
           p.ProcessNode.value('@lockMode', 'varchar(10)')                        AS RequestedLockMode,
           p.ProcessNode.value('@waitresource', 'nvarchar(100)')                  AS WaitResource,
           p.ProcessNode.value('@isolationlevel', 'nvarchar(40)')                 AS IsolationLevel,
           LTRIM(RTRIM(REPLACE(REPLACE(p.ProcessNode.value('(inputbuf/text())[1]', 'nvarchar(400)'), NCHAR(10), N' '), NCHAR(13), N' '))) AS InputBuffer
    FROM (
        SELECT e.EventNode.value('@timestamp', 'datetime2(3)') AS EventTimeUtc,
               e.EventNode.value('(data[@name="xml_report"]/value/deadlock/victim-list/victimProcess/@id)[1]', 'varchar(60)') AS VictimProcessId,
               e.EventNode.query('data[@name="xml_report"]/value/deadlock') AS Graph
        FROM @RingBuffer.nodes('/RingBufferTarget/event[@name="xml_deadlock_report"]') AS e (EventNode)
    ) AS d
    CROSS APPLY d.Graph.nodes('/deadlock/process-list/process') AS p (ProcessNode)
    ORDER BY d.EventTimeUtc, IsVictim DESC;

    RETURN 0;
END;
GO

-- ---------------------------------------------------------------------------
-- Wait statistics. The counters are cumulative since startup, so one reading
-- means little; the difference between two readings shows what the instance
-- waited on during that interval.
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dba.usp_CaptureWaitStats
AS
BEGIN
    SET NOCOUNT ON;

    INSERT dba.WaitStatsSnapshot (CapturedAt, WaitType, WaitingTasks, WaitTimeMs, SignalWaitTimeMs)
    SELECT SYSDATETIME(), ws.wait_type, ws.waiting_tasks_count, ws.wait_time_ms, ws.signal_wait_time_ms
    FROM sys.dm_os_wait_stats AS ws
    WHERE ws.waiting_tasks_count > 0
      -- idle and background waits that say nothing about user workload
      AND ws.wait_type NOT LIKE N'SLEEP[_]%'
      AND ws.wait_type NOT LIKE N'BROKER[_]%'
      AND ws.wait_type NOT LIKE N'XE[_]%'
      AND ws.wait_type NOT LIKE N'HADR[_]%'
      AND ws.wait_type NOT LIKE N'QDS[_]%'
      AND ws.wait_type NOT LIKE N'SP[_]SERVER[_]DIAGNOSTICS%'
      AND ws.wait_type NOT LIKE N'PREEMPTIVE[_]%'
      AND ws.wait_type NOT IN (N'LAZYWRITER_SLEEP', N'SQLTRACE_BUFFER_FLUSH', N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
                               N'WAITFOR', N'LOGMGR_QUEUE', N'CHECKPOINT_QUEUE', N'REQUEST_FOR_DEADLOCK_SEARCH',
                               N'CLR_AUTO_EVENT', N'CLR_MANUAL_EVENT', N'CLR_SEMAPHORE', N'DIRTY_PAGE_POLL',
                               N'DISPATCHER_QUEUE_SEMAPHORE', N'FT_IFTS_SCHEDULER_IDLE_WAIT', N'ONDEMAND_TASK_QUEUE',
                               N'DBMIRROR_EVENTS_QUEUE', N'DBMIRRORING_CMD', N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG',
                               N'SOS_WORK_DISPATCHER', N'PVS_PREALLOCATE', N'PARALLEL_REDO_WORKER_WAIT_WORK',
                               N'RESOURCE_QUEUE', N'SERVER_IDLE_CHECK', N'WAIT_XTP_HOST_WAIT', N'VDI_CLIENT_OTHER',
                               N'KSOURCE_WAKEUP', N'STARTUP_DEPENDENCY_MANAGER', N'XTP_PREEMPTIVE_TASK');
END;
GO

CREATE OR ALTER PROCEDURE dba.usp_WaitStatsDelta
    @Top int = 10
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Current datetime2(3), @Previous datetime2(3);

    SELECT @Current = MAX(w.CapturedAt) FROM dba.WaitStatsSnapshot AS w;
    SELECT @Previous = MAX(w.CapturedAt) FROM dba.WaitStatsSnapshot AS w WHERE w.CapturedAt < @Current;

    IF @Previous IS NULL
    BEGIN
        PRINT N'Two snapshots are needed. Run dba.usp_CaptureWaitStats again after some workload.';
        RETURN 0;
    END;

    SELECT TOP (@Top)
           c.WaitType,
           c.WaitingTasks - ISNULL(p.WaitingTasks, 0)                                        AS WaitingTasks,
           c.WaitTimeMs - ISNULL(p.WaitTimeMs, 0)                                            AS TotalWaitMs,
           (c.WaitTimeMs - ISNULL(p.WaitTimeMs, 0))
               - (c.SignalWaitTimeMs - ISNULL(p.SignalWaitTimeMs, 0))                        AS ResourceWaitMs,
           c.SignalWaitTimeMs - ISNULL(p.SignalWaitTimeMs, 0)                                AS SignalWaitMs,
           DATEDIFF(SECOND, @Previous, @Current)                                             AS IntervalSeconds
    FROM dba.WaitStatsSnapshot AS c
    LEFT JOIN dba.WaitStatsSnapshot AS p
           ON p.CapturedAt = @Previous AND p.WaitType = c.WaitType
    WHERE c.CapturedAt = @Current
      AND c.WaitTimeMs - ISNULL(p.WaitTimeMs, 0) > 0
    ORDER BY TotalWaitMs DESC;
END;
GO

-- ---------------------------------------------------------------------------
-- File sizes and space used for every online database. Scheduled daily, this
-- table answers "when will we run out of disk?" with data instead of a guess.
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dba.usp_CaptureDatabaseSize
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now  datetime2(0) = SYSDATETIME(),
            @Home nvarchar(300) = QUOTENAME(DB_NAME()),
            @Db   sysname,
            @Sql  nvarchar(max);

    DECLARE SizeDatabases CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.state_desc = N'ONLINE'
          AND d.user_access_desc = N'MULTI_USER'
        ORDER BY d.name;

    OPEN SizeDatabases;
    FETCH NEXT FROM SizeDatabases INTO @Db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Sql = N'USE ' + QUOTENAME(@Db) + N';
            INSERT ' + @Home + N'.dba.DatabaseSizeHistory (CapturedAt, DatabaseName, LogicalFileName, FileType, FileGroupName, SizeMB, UsedMB, GrowthSetting)
            SELECT @Now, DB_NAME(), f.name, f.type_desc, fg.name,
                   CAST(f.size / 128.0 AS decimal(12,1)),
                   CAST(CAST(FILEPROPERTY(f.name, ''SpaceUsed'') AS int) / 128.0 AS decimal(12,1)),
                   CASE WHEN f.is_percent_growth = 1 THEN CAST(f.growth AS varchar(10)) + '' percent''
                        WHEN f.growth = 0 THEN ''none''
                        ELSE CAST(f.growth / 128 AS varchar(10)) + '' MB'' END
            FROM sys.database_files AS f
            LEFT JOIN sys.filegroups AS fg ON fg.data_space_id = f.data_space_id;';

        BEGIN TRY
            EXEC sys.sp_executesql @Sql, N'@Now datetime2(0)', @Now = @Now;
        END TRY
        BEGIN CATCH
            PRINT N'Size capture skipped for ' + @Db + N': ' + ERROR_MESSAGE();
        END CATCH;

        FETCH NEXT FROM SizeDatabases INTO @Db;
    END;

    CLOSE SizeDatabases;
    DEALLOCATE SizeDatabases;

    SELECT h.DatabaseName, h.LogicalFileName, h.FileType, h.FileGroupName, h.SizeMB, h.UsedMB,
           CAST(100.0 * h.UsedMB / NULLIF(h.SizeMB, 0) AS decimal(5,1)) AS UsedPct,
           h.GrowthSetting
    FROM dba.DatabaseSizeHistory AS h
    WHERE h.CapturedAt = @Now
    ORDER BY h.DatabaseName, h.FileType DESC, h.LogicalFileName;
END;
GO
