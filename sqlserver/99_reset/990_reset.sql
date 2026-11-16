/*
    990_reset.sql

    Remove everything the lab created, so the next deployment starts clean:
    databases (with their msdb backup history), audit objects, the Extended Events
    session, Agent jobs, logins and the custom server role. Backup and audit files
    are removed by scripts/reset.sh.

    This is the only script in the repository that drops databases, and it only
    touches databases named TransitOps, TransitOps_<suffix> and DBAdmin.
*/
SET NOCOUNT ON;
USE master;
GO

DECLARE @Db sysname, @Sql nvarchar(max);

DECLARE LabDatabases CURSOR LOCAL FAST_FORWARD FOR
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.name = N'TransitOps' OR d.name LIKE N'TransitOps[_]%' OR d.name = N'DBAdmin';

OPEN LabDatabases;
FETCH NEXT FROM LabDatabases INTO @Db;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF CAST(DATABASEPROPERTYEX(@Db, 'Status') AS nvarchar(60)) = N'ONLINE'
    BEGIN
        SET @Sql = N'ALTER DATABASE ' + QUOTENAME(@Db) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;';
        EXEC sys.sp_executesql @Sql;
    END;

    EXEC msdb.dbo.sp_delete_database_backuphistory @database_name = @Db;

    SET @Sql = N'DROP DATABASE ' + QUOTENAME(@Db) + N';';
    EXEC sys.sp_executesql @Sql;

    PRINT 'Dropped ' + @Db;
    FETCH NEXT FROM LabDatabases INTO @Db;
END;

CLOSE LabDatabases;
DEALLOCATE LabDatabases;
GO

IF EXISTS (SELECT 1 FROM sys.server_audit_specifications AS s WHERE s.name = N'AuditSpec_Server_Security')
BEGIN
    ALTER SERVER AUDIT SPECIFICATION AuditSpec_Server_Security WITH (STATE = OFF);
    DROP SERVER AUDIT SPECIFICATION AuditSpec_Server_Security;
END;

IF EXISTS (SELECT 1 FROM sys.server_audits AS a WHERE a.name = N'Audit_TransitOps')
BEGIN
    ALTER SERVER AUDIT Audit_TransitOps WITH (STATE = OFF);
    DROP SERVER AUDIT Audit_TransitOps;
END;

IF EXISTS (SELECT 1 FROM sys.server_event_sessions AS s WHERE s.name = N'DBA_Concurrency')
    DROP EVENT SESSION DBA_Concurrency ON SERVER;
GO

DECLARE @Job sysname;

DECLARE LabJobs CURSOR LOCAL FAST_FORWARD FOR
    SELECT j.name FROM msdb.dbo.sysjobs AS j WHERE j.name LIKE N'DBA - %';

OPEN LabJobs;
FETCH NEXT FROM LabJobs INTO @Job;

WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC msdb.dbo.sp_delete_job @job_name = @Job, @delete_unused_schedule = 1;
    FETCH NEXT FROM LabJobs INTO @Job;
END;

CLOSE LabJobs;
DEALLOCATE LabJobs;
GO

DECLARE @Login sysname, @Sql nvarchar(max);

DECLARE LabLogins CURSOR LOCAL FAST_FORWARD FOR
    SELECT sp.name
    FROM sys.server_principals AS sp
    WHERE sp.name IN (N'svc_transit_app', N'svc_reporting', N'dev_analyst', N'maint_supervisor_north', N'hr_admin', N'dba_junior');

OPEN LabLogins;
FETCH NEXT FROM LabLogins INTO @Login;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Sql = N'DROP LOGIN ' + QUOTENAME(@Login) + N';';
    EXEC sys.sp_executesql @Sql;
    FETCH NEXT FROM LabLogins INTO @Login;
END;

CLOSE LabLogins;
DEALLOCATE LabLogins;

IF EXISTS (SELECT 1 FROM sys.server_principals AS sp WHERE sp.name = N'srv_dba_junior' AND sp.type = 'R')
    DROP SERVER ROLE srv_dba_junior;
GO

PRINT 'Reset complete.';
GO
