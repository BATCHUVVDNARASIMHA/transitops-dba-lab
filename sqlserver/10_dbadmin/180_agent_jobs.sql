/*
    180_agent_jobs.sql

    SQL Server Agent jobs: the schedule that turns the procedures into operations.

    Jobs are created DISABLED in the lab (dba.Config 'AgentJobsEnabled' = 0) so a
    container left running does not fill its volume with backups. Set the value to 1
    and rerun this script to deploy them enabled.

    Job steps only call stored procedures. An Agent T-SQL step runs with
    QUOTED_IDENTIFIER OFF, which breaks direct DML against tables with filtered
    indexes or indexed views; a procedure keeps the setting it was created with.
*/
SET NOCOUNT ON;
USE DBAdmin;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dba.usp_DeployJob
    @JobName             sysname,
    @Description         nvarchar(512),
    @Command             nvarchar(max),
    @FreqType            int,            -- 4 = daily, 8 = weekly
    @FreqInterval        int,            -- daily: every N days. weekly: bitmask of days (1 = Sunday, 64 = Saturday)
    @FreqSubdayType      int = 1,        -- 1 = at the start time, 4 = every N minutes, 8 = every N hours
    @FreqSubdayInterval  int = 0,
    @ActiveStartTime     int = 0,        -- HHMMSS
    @Enabled             bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @JobId      uniqueidentifier,
            @Recurrence int = CASE WHEN @FreqType = 8 THEN 1 ELSE 0 END,   -- weekly schedules need "every 1 week"
            @Schedule   sysname = LEFT(@JobName + N' schedule', 128);

    IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs AS j WHERE j.name = @JobName)
        EXEC msdb.dbo.sp_delete_job @job_name = @JobName, @delete_unused_schedule = 1;

    EXEC msdb.dbo.sp_add_job
         @job_name         = @JobName,
         @enabled          = @Enabled,
         @description      = @Description,
         @category_name    = N'Database Maintenance',
         @owner_login_name = N'sa',
         @job_id           = @JobId OUTPUT;

    EXEC msdb.dbo.sp_add_jobstep
         @job_id            = @JobId,
         @step_name         = N'Run',
         @subsystem         = N'TSQL',
         @database_name     = N'DBAdmin',
         @command           = @Command,
         @retry_attempts    = 1,
         @retry_interval    = 1,
         @on_success_action = 1,     -- quit reporting success
         @on_fail_action    = 2;     -- quit reporting failure

    EXEC msdb.dbo.sp_add_jobschedule
         @job_id                 = @JobId,
         @name                   = @Schedule,
         @enabled                = 1,
         @freq_type              = @FreqType,
         @freq_interval          = @FreqInterval,
         @freq_subday_type       = @FreqSubdayType,
         @freq_subday_interval   = @FreqSubdayInterval,
         @freq_recurrence_factor = @Recurrence,
         @active_start_time      = @ActiveStartTime;

    EXEC msdb.dbo.sp_add_jobserver @job_id = @JobId;
END;
GO

DECLARE @Enabled bit = CASE WHEN dba.fn_GetConfig(N'AgentJobsEnabled') = N'1' THEN 1 ELSE 0 END;

EXEC dba.usp_DeployJob
     @JobName = N'DBA - Backup FULL', @Enabled = @Enabled,
     @Description = N'Full backup of every database with a full-backup interval in dba.BackupPolicy. Daily at 01:00.',
     @Command = N'EXEC dba.usp_BackupPerPolicy @BackupType = ''FULL'';',
     @FreqType = 4, @FreqInterval = 1, @ActiveStartTime = 10000;

EXEC dba.usp_DeployJob
     @JobName = N'DBA - Backup DIFF', @Enabled = @Enabled,
     @Description = N'Differential backup per policy. Every 6 hours.',
     @Command = N'EXEC dba.usp_BackupPerPolicy @BackupType = ''DIFF'';',
     @FreqType = 4, @FreqInterval = 1, @FreqSubdayType = 8, @FreqSubdayInterval = 6, @ActiveStartTime = 30000;

EXEC dba.usp_DeployJob
     @JobName = N'DBA - Backup LOG', @Enabled = @Enabled,
     @Description = N'Transaction log backup per policy. Every 15 minutes: this interval is the RPO.',
     @Command = N'EXEC dba.usp_BackupPerPolicy @BackupType = ''LOG'';',
     @FreqType = 4, @FreqInterval = 1, @FreqSubdayType = 4, @FreqSubdayInterval = 15;

EXEC dba.usp_DeployJob
     @JobName = N'DBA - Integrity Check', @Enabled = @Enabled,
     @Description = N'DBCC CHECKDB on every policy database. Sunday 02:00.',
     @Command = N'EXEC dba.usp_IntegrityCheck;',
     @FreqType = 8, @FreqInterval = 1, @ActiveStartTime = 20000;

EXEC dba.usp_DeployJob
     @JobName = N'DBA - Index and Statistics Maintenance', @Enabled = @Enabled,
     @Description = N'Fragmentation-driven index maintenance and statistics updates for TransitOps. Saturday 03:00.',
     @Command = N'EXEC dba.usp_IndexMaintenance @DatabaseName = N''TransitOps''; EXEC dba.usp_UpdateStatistics @DatabaseName = N''TransitOps'';',
     @FreqType = 8, @FreqInterval = 64, @ActiveStartTime = 30000;

EXEC dba.usp_DeployJob
     @JobName = N'DBA - Restore Drill', @Enabled = @Enabled,
     @Description = N'Restores TransitOps from its backup chain to a side database, runs CHECKDB, logs recovery time. Sunday 04:00.',
     @Command = N'EXEC dba.usp_RestoreDrill @SourceDatabase = N''TransitOps'', @TargetDatabase = N''TransitOps_DRDrill'';',
     @FreqType = 8, @FreqInterval = 1, @ActiveStartTime = 40000;

EXEC dba.usp_DeployJob
     @JobName = N'DBA - Health Check', @Enabled = @Enabled,
     @Description = N'Stores a health check run in dba.HealthCheckResult. Hourly.',
     @Command = N'EXEC dba.usp_HealthCheck @Quiet = 1;',
     @FreqType = 4, @FreqInterval = 1, @FreqSubdayType = 8, @FreqSubdayInterval = 1;

EXEC dba.usp_DeployJob
     @JobName = N'DBA - Capture Baselines', @Enabled = @Enabled,
     @Description = N'Wait statistics and database size snapshots for trending. Daily at 00:30.',
     @Command = N'EXEC dba.usp_CaptureWaitStats; EXEC dba.usp_CaptureDatabaseSize;',
     @FreqType = 4, @FreqInterval = 1, @ActiveStartTime = 3000;

EXEC dba.usp_DeployJob
     @JobName = N'DBA - Purge History', @Enabled = @Enabled,
     @Description = N'Purges msdb history, DBAdmin run logs and expired backup files. Sunday 05:00.',
     @Command = N'EXEC dba.usp_PurgeHistory @RetentionDays = 30, @PurgeBackupFiles = 1;',
     @FreqType = 8, @FreqInterval = 1, @ActiveStartTime = 50000;
GO

SELECT CAST(j.name AS nvarchar(45)) AS JobName,
       j.enabled                    AS Enabled,
       CAST(CASE s.freq_type WHEN 4 THEN 'Daily' WHEN 8 THEN 'Weekly' ELSE 'Other' END
            + CASE s.freq_subday_type
                  WHEN 4 THEN ', every ' + CAST(s.freq_subday_interval AS varchar(10)) + ' min'
                  WHEN 8 THEN ', every ' + CAST(s.freq_subday_interval AS varchar(10)) + ' h'
                  ELSE ', at ' + STUFF(STUFF(RIGHT('000000' + CAST(s.active_start_time AS varchar(6)), 6), 5, 0, ':'), 3, 0, ':')
              END AS varchar(40))   AS Schedule
FROM msdb.dbo.sysjobs AS j
JOIN msdb.dbo.sysjobschedules AS js ON js.job_id = j.job_id
JOIN msdb.dbo.sysschedules AS s ON s.schedule_id = js.schedule_id
WHERE j.name LIKE N'DBA - %'
ORDER BY j.name;
GO
