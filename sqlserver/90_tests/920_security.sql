/*
    920_security.sql
    Permission tests by impersonation: become each persona and try what it should
    and should not be able to do.
*/
SET NOCOUNT ON;
USE TransitOps;
GO

DECLARE @ok bit, @detail nvarchar(1000), @n int, @m int, @c int, @err int, @txt nvarchar(200);

-- ---------------------------------------------------------------- reporting account
SELECT @err = 0, @n = NULL;
EXECUTE AS USER = N'svc_reporting';
BEGIN TRY
    SELECT @n = COUNT(*) FROM ops.Operator;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
END CATCH;
REVERT;
SELECT @ok = CASE WHEN @err = 229 THEN 1 ELSE 0 END, @detail = N'error ' + CAST(@err AS nvarchar(10));
EXEC DBAdmin.dba.usp_Assert 'security', N'Reporting account is denied the operator (PII) table', @ok, @detail;

SELECT @err = 0, @n = NULL;
EXECUTE AS USER = N'svc_reporting';
BEGIN TRY
    SELECT @n = COUNT(DISTINCT w.GarageName) FROM rpt.vw_OpenWorkOrders AS w;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
END CATCH;
REVERT;
SELECT @ok = CASE WHEN @err = 0 AND @n = 4 THEN 1 ELSE 0 END,
       @detail = N'error ' + CAST(@err AS nvarchar(10)) + N', garages visible ' + ISNULL(CAST(@n AS nvarchar(10)), N'none');
EXEC DBAdmin.dba.usp_Assert 'security', N'Reporting account reads reporting views across all garages', @ok, @detail;

-- ---------------------------------------------------------------- developer: masked
SELECT @err = 0, @txt = NULL;
EXECUTE AS USER = N'dev_analyst';
BEGIN TRY
    SELECT TOP (1) @txt = o.Email FROM ops.Operator AS o ORDER BY o.OperatorId;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
END CATCH;
REVERT;
SELECT @ok = CASE WHEN @err = 0 AND @txt LIKE N'%XXX@XXXX.com' THEN 1 ELSE 0 END, @detail = N'sees ' + ISNULL(@txt, N'nothing');
EXEC DBAdmin.dba.usp_Assert 'security', N'Developer sees operator e-mail masked', @ok, @detail;

SELECT @err = 0;
EXECUTE AS USER = N'dev_analyst';
BEGIN TRY
    UPDATE ref.Route SET IsActive = IsActive WHERE RouteId = 1;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
END CATCH;
REVERT;
SELECT @ok = CASE WHEN @err = 229 THEN 1 ELSE 0 END, @detail = N'error ' + CAST(@err AS nvarchar(10));
EXEC DBAdmin.dba.usp_Assert 'security', N'Developer cannot modify data', @ok, @detail;

-- ---------------------------------------------------------------- HR: unmasked (this SELECT is also what the audit test looks for)
SELECT @err = 0, @txt = NULL;
EXECUTE AS USER = N'hr_admin';
BEGIN TRY
    SELECT TOP (1) @txt = o.Email FROM ops.Operator AS o ORDER BY o.OperatorId;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
END CATCH;
REVERT;
SELECT @ok = CASE WHEN @err = 0 AND @txt LIKE N'%@transitops.example' THEN 1 ELSE 0 END, @detail = N'error ' + CAST(@err AS nvarchar(10));
EXEC DBAdmin.dba.usp_Assert 'security', N'HR role sees operator e-mail unmasked', @ok, @detail;

-- ---------------------------------------------------------------- row-level security
SELECT @err = 0, @n = NULL, @m = NULL, @c = NULL;
EXECUTE AS USER = N'maint_supervisor_north';
BEGIN TRY
    SELECT @n = COUNT(DISTINCT w.GarageId), @m = MIN(w.GarageId), @c = COUNT(*) FROM maint.WorkOrder AS w;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
END CATCH;
REVERT;
SELECT @ok = CASE WHEN @err = 0 AND @n = 1 AND @m = 1 AND @c > 0 THEN 1 ELSE 0 END,
       @detail = ISNULL(CAST(@c AS nvarchar(10)), N'0') + N' work orders visible, all in garage ' + ISNULL(CAST(@m AS nvarchar(10)), N'?');
EXEC DBAdmin.dba.usp_Assert 'security', N'Garage supervisor sees only their own garage (row-level security)', @ok, @detail;

SELECT @err = 0;
EXECUTE AS USER = N'maint_supervisor_north';
BEGIN TRY
    UPDATE TOP (1) maint.WorkOrder SET GarageId = 2 WHERE GarageId = 1;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
END CATCH;
REVERT;
SELECT @ok = CASE WHEN @err <> 0 THEN 1 ELSE 0 END, @detail = N'error ' + CAST(@err AS nvarchar(10));
EXEC DBAdmin.dba.usp_Assert 'security', N'Garage supervisor cannot move a work order to another garage', @ok, @detail;

-- ---------------------------------------------------------------- application account
SELECT @err = 0;
EXECUTE AS USER = N'svc_transit_app';
BEGIN TRY
    EXEC app.usp_RecordTap @CardId = 1, @StopId = 1, @FareProductId = 1, @TapType = 'E', @TapDateTime = '2026-11-15T08:00:00';
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
END CATCH;
REVERT;
SELECT @ok = CASE WHEN @err = 0 THEN 1 ELSE 0 END, @detail = N'error ' + CAST(@err AS nvarchar(10));
EXEC DBAdmin.dba.usp_Assert 'security', N'Application account can record a tap through its stored procedure', @ok, @detail;

SELECT @err = 0, @n = NULL;
EXECUTE AS USER = N'svc_transit_app';
BEGIN TRY
    SELECT @n = COUNT(*) FROM fare.FareProduct;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
END CATCH;
REVERT;
SELECT @ok = CASE WHEN @err = 229 THEN 1 ELSE 0 END, @detail = N'error ' + CAST(@err AS nvarchar(10));
EXEC DBAdmin.dba.usp_Assert 'security', N'Application account has no direct table access', @ok, @detail;
GO

-- ---------------------------------------------------------------- junior DBA (server level)
USE master;
GO

DECLARE @ok bit, @detail nvarchar(1000),
        @ViewState int, @SysAdmin int, @Health int, @Restore int, @Backup int, @Data int;

EXECUTE AS LOGIN = N'dba_junior';
SELECT @ViewState = HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE'),
       @SysAdmin  = IS_SRVROLEMEMBER('sysadmin'),
       @Health    = HAS_PERMS_BY_NAME(N'DBAdmin.dba.usp_HealthCheck', 'OBJECT', 'EXECUTE'),
       @Restore   = HAS_PERMS_BY_NAME(N'DBAdmin.dba.usp_RestoreFromHistory', 'OBJECT', 'EXECUTE'),
       @Backup    = HAS_PERMS_BY_NAME(N'TransitOps', 'DATABASE', 'BACKUP DATABASE'),
       @Data      = HAS_PERMS_BY_NAME(N'TransitOps.ops.Operator', 'OBJECT', 'SELECT');
REVERT;

SELECT @ok = CASE WHEN @ViewState = 1 AND @Health = 1 AND @Backup = 1 THEN 1 ELSE 0 END,
       @detail = N'view server state ' + ISNULL(CAST(@ViewState AS nvarchar(5)), N'null')
               + N', health check ' + ISNULL(CAST(@Health AS nvarchar(5)), N'null')
               + N', backup ' + ISNULL(CAST(@Backup AS nvarchar(5)), N'null');
EXEC DBAdmin.dba.usp_Assert 'security', N'DBA I can monitor, run the health check and take backups', @ok, @detail;

SELECT @ok = CASE WHEN ISNULL(@SysAdmin, 0) = 0 AND ISNULL(@Restore, 0) = 0 AND ISNULL(@Data, 0) = 0 THEN 1 ELSE 0 END,
       @detail = N'sysadmin ' + ISNULL(CAST(@SysAdmin AS nvarchar(5)), N'null')
               + N', restore ' + ISNULL(CAST(@Restore AS nvarchar(5)), N'null')
               + N', operator data ' + ISNULL(CAST(@Data AS nvarchar(5)), N'null');
EXEC DBAdmin.dba.usp_Assert 'security', N'DBA I is not sysadmin, cannot restore, cannot read personal data', @ok, @detail;
GO

-- ---------------------------------------------------------------- audit
WAITFOR DELAY '00:00:03';     -- the audit queue flushes every second
GO

DECLARE @ok bit, @detail nvarchar(1000), @n int, @Pattern nvarchar(400);

SELECT @n = COUNT(*) FROM sys.dm_server_audit_status AS a WHERE a.name = N'Audit_TransitOps' AND a.status_desc = N'STARTED';
SELECT @ok = CASE WHEN @n = 1 THEN 1 ELSE 0 END, @detail = NULL;
EXEC DBAdmin.dba.usp_Assert 'security', N'Server audit is running', @ok, @detail;

SET @Pattern = DBAdmin.dba.fn_GetConfig(N'AuditPath');
SET @Pattern = @Pattern + CASE WHEN @Pattern LIKE N'/%' THEN N'/' ELSE N'\' END + N'*.sqlaudit';

SELECT @n = COUNT(*)
FROM sys.fn_get_audit_file(@Pattern, DEFAULT, DEFAULT) AS a
WHERE a.database_name = N'TransitOps'
  AND a.object_name = N'Operator'
  AND a.action_id = 'SL'
  AND a.database_principal_name = N'hr_admin';

SELECT @ok = CASE WHEN @n >= 1 THEN 1 ELSE 0 END, @detail = CAST(@n AS nvarchar(10)) + N' audit record(s)';
EXEC DBAdmin.dba.usp_Assert 'security', N'Audit recorded the HR read of operator personal data', @ok, @detail;
GO
