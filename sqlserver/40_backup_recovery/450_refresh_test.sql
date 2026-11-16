/*
    450_refresh_test.sql

    Refresh the TEST environment from production backups. The copy is switched to
    SIMPLE recovery and operator personal data is replaced before the procedure
    returns. Developers get realistic volumes and distributions, not real people.
*/
SET NOCOUNT ON;
USE DBAdmin;
GO

EXEC dba.usp_RefreshLowerEnvironment
     @SourceDatabase = N'TransitOps',
     @TargetDatabase = N'TransitOps_TEST';
GO

SELECT TOP (3)
       o.OperatorId, o.FirstName, o.LastName, o.Email, o.Phone, o.LicenseNumber
FROM TransitOps_TEST.ops.Operator AS o
ORDER BY o.OperatorId;

SELECT CAST(d.DrillType AS varchar(14))      AS DrillType,
       CAST(d.TargetDatabase AS nvarchar(20)) AS TargetDatabase,
       d.BackupFilesRestored                  AS Files,
       d.RestoreSeconds,
       d.RtoTargetSeconds,
       d.RpoExposureSeconds,
       d.CheckDbStatus,
       d.ValidationStatus,
       d.Status
FROM dba.RestoreDrillLog AS d
ORDER BY d.DrillId;
GO
