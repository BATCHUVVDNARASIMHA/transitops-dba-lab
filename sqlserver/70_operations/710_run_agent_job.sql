/*
    710_run_agent_job.sql

    Start the health check job through SQL Server Agent and wait for the outcome.
    Proves that the scheduler, the job definition and the procedure work together,
    not just the procedure on its own.
*/
SET NOCOUNT ON;
USE msdb;
GO

DECLARE @Job     sysname  = N'DBA - Health Check',
        @Started datetime = GETDATE(),
        @Status  int,
        @Tries   int = 0;

EXEC msdb.dbo.sp_start_job @job_name = @Job;

WHILE @Tries < 60 AND @Status IS NULL
BEGIN
    WAITFOR DELAY '00:00:02';

    SELECT TOP (1) @Status = h.run_status
    FROM msdb.dbo.sysjobhistory AS h
    JOIN msdb.dbo.sysjobs AS j ON j.job_id = h.job_id
    WHERE j.name = @Job
      AND h.step_id = 0
      AND msdb.dbo.agent_datetime(h.run_date, h.run_time) >= DATEADD(SECOND, -5, @Started)
    ORDER BY h.instance_id DESC;

    SET @Tries += 1;
END;

IF @Status IS NULL
BEGIN
    RAISERROR(N'The Agent job did not report an outcome within two minutes.', 16, 1);
    RETURN;
END;

IF @Status <> 1
BEGIN
    RAISERROR(N'The Agent job finished with run_status %d. See msdb.dbo.sysjobhistory.', 16, 1, @Status);
    RETURN;
END;

PRINT 'Agent job "DBA - Health Check" succeeded.';
GO
