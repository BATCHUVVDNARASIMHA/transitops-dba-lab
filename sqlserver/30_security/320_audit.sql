/*
    320_audit.sql

    SQL Server Audit.

      Server audit            Audit_TransitOps, written to files outside the data folder
      Server specification    failed logins, role membership and permission changes,
                              login changes, audit changes, backup and restore
      Database specification  every SELECT, UPDATE and DELETE on ops.Operator (personal
                              data) by anyone, plus all schema changes in TransitOps

    ON_FAILURE = CONTINUE keeps the instance available if the audit target fills up.
    A regulated system might choose SHUTDOWN or FAIL_OPERATION instead; that is a
    business decision about whether unaudited activity is worse than an outage.
*/
SET NOCOUNT ON;
USE master;
GO

DECLARE @AuditPath nvarchar(260) = DBAdmin.dba.fn_GetConfig(N'AuditPath'),
        @Sql       nvarchar(max);

IF @AuditPath IS NULL
BEGIN
    RAISERROR(N'dba.Config has no AuditPath.', 16, 1);
    RETURN;
END;

-- Create the folder if the service account is allowed to. The deployment script
-- also creates it, so a failure here is not fatal.
BEGIN TRY
    EXEC master.dbo.xp_create_subdir @AuditPath;
END TRY
BEGIN CATCH
    PRINT N'Could not create ' + @AuditPath + N': ' + ERROR_MESSAGE();
END CATCH;

IF NOT EXISTS (SELECT 1 FROM sys.server_audits AS a WHERE a.name = N'Audit_TransitOps')
BEGIN
    SET @Sql = N'CREATE SERVER AUDIT Audit_TransitOps
                 TO FILE (FILEPATH = N''' + REPLACE(@AuditPath, N'''', N'''''') + N''', MAXSIZE = 64 MB, MAX_ROLLOVER_FILES = 8, RESERVE_DISK_SPACE = OFF)
                 WITH (QUEUE_DELAY = 1000, ON_FAILURE = CONTINUE);';
    EXEC sys.sp_executesql @Sql;
END;
GO

ALTER SERVER AUDIT Audit_TransitOps WITH (STATE = ON);
GO

IF NOT EXISTS (SELECT 1 FROM sys.server_audit_specifications AS s WHERE s.name = N'AuditSpec_Server_Security')
    CREATE SERVER AUDIT SPECIFICATION AuditSpec_Server_Security
    FOR SERVER AUDIT Audit_TransitOps
        ADD (FAILED_LOGIN_GROUP),
        ADD (SERVER_ROLE_MEMBER_CHANGE_GROUP),
        ADD (SERVER_PRINCIPAL_CHANGE_GROUP),
        ADD (SERVER_PERMISSION_CHANGE_GROUP),
        ADD (DATABASE_ROLE_MEMBER_CHANGE_GROUP),
        ADD (DATABASE_PERMISSION_CHANGE_GROUP),
        ADD (LOGIN_CHANGE_PASSWORD_GROUP),
        ADD (AUDIT_CHANGE_GROUP),
        ADD (BACKUP_RESTORE_GROUP)
    WITH (STATE = ON);
GO

USE TransitOps;
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_audit_specifications AS s WHERE s.name = N'AuditSpec_TransitOps_Sensitive')
    CREATE DATABASE AUDIT SPECIFICATION AuditSpec_TransitOps_Sensitive
    FOR SERVER AUDIT Audit_TransitOps
        ADD (SELECT, UPDATE, DELETE ON OBJECT::ops.Operator BY public),
        ADD (SCHEMA_OBJECT_CHANGE_GROUP)
    WITH (STATE = ON);
GO

SELECT CAST(a.name AS nvarchar(24))         AS AuditName,
       CAST(a.status_desc AS nvarchar(12))  AS AuditStatus,
       CAST(a.audit_file_path AS nvarchar(70)) AS CurrentFile
FROM sys.dm_server_audit_status AS a;
GO
