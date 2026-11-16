/*
    910_recoverability.sql
    Assertions on the database build, the backup chain and the restore drills.
    Each assertion writes a row to dba.TestResult; 990_summary.sql fails the run if any failed.
*/
SET NOCOUNT ON;
USE DBAdmin;
GO

DECLARE @ok bit, @detail nvarchar(1000), @n bigint, @m bigint;

-- ---------------------------------------------------------------- build
SELECT @ok = CASE WHEN d.state_desc = N'ONLINE' AND d.recovery_model_desc = N'FULL'
                       AND d.page_verify_option_desc = N'CHECKSUM' AND d.is_query_store_on = 1 THEN 1 ELSE 0 END,
       @detail = CAST(d.recovery_model_desc AS nvarchar(20)) + N' recovery, page verify ' + CAST(d.page_verify_option_desc AS nvarchar(20))
FROM sys.databases AS d
WHERE d.name = N'TransitOps';
EXEC dba.usp_Assert 'build', N'TransitOps is online, FULL recovery, CHECKSUM page verify, Query Store on', @ok, @detail;

SELECT @n = (SELECT COUNT_BIG(*) FROM TransitOps.fare.Tap) + (SELECT COUNT_BIG(*) FROM TransitOps.fare.TapArchive);
SELECT @ok = CASE WHEN @n >= 1500000 THEN 1 ELSE 0 END, @detail = CAST(@n AS nvarchar(20)) + N' taps in live and archive tables';
EXEC dba.usp_Assert 'build', N'Fare tap volume loaded', @ok, @detail;

SELECT @n = (SELECT COUNT(*) FROM TransitOps.sys.foreign_keys AS fk WHERE fk.is_not_trusted = 1)
          + (SELECT COUNT(*) FROM TransitOps.sys.check_constraints AS ck WHERE ck.is_not_trusted = 1);
SELECT @ok = CASE WHEN @n = 0 THEN 1 ELSE 0 END, @detail = CAST(@n AS nvarchar(20)) + N' untrusted';
EXEC dba.usp_Assert 'build', N'Every foreign key and check constraint is trusted', @ok, @detail;

-- ---------------------------------------------------------------- backups
SELECT @n = COUNT(*),
       @m = SUM(CASE WHEN l.Status = 'SUCCEEDED' AND l.Verified = 1 THEN 1 ELSE 0 END)
FROM dba.BackupLog AS l;
SELECT @ok = CASE WHEN @n >= 8 AND @n = @m THEN 1 ELSE 0 END,
       @detail = CAST(@m AS nvarchar(20)) + N' of ' + CAST(@n AS nvarchar(20)) + N' backups succeeded and verified';
EXEC dba.usp_Assert 'backup', N'Every backup succeeded and passed RESTORE VERIFYONLY', @ok, @detail;

SELECT @n = COUNT(*)
FROM (
    SELECT bs.first_lsn,
           LAG(bs.last_lsn) OVER (ORDER BY bs.last_lsn) AS previous_last_lsn
    FROM msdb.dbo.backupset AS bs
    WHERE bs.database_name = N'TransitOps'
      AND bs.type = 'L'
      AND bs.database_guid = (SELECT TOP (1) x.database_guid
                              FROM msdb.dbo.backupset AS x
                              WHERE x.database_name = N'TransitOps'
                              ORDER BY x.backup_set_id DESC)
) AS q
WHERE q.previous_last_lsn IS NOT NULL
  AND q.first_lsn <> q.previous_last_lsn;
SELECT @ok = CASE WHEN @n = 0 THEN 1 ELSE 0 END, @detail = CAST(@n AS nvarchar(20)) + N' gap(s)';
EXEC dba.usp_Assert 'backup', N'TransitOps log backup chain has no gaps', @ok, @detail;

SELECT @n = COUNT(*)
FROM msdb.dbo.backupset AS bs
WHERE bs.database_name = N'TransitOps' AND bs.type = 'D' AND bs.is_copy_only = 1;
SELECT @ok = CASE WHEN @n >= 1 THEN 1 ELSE 0 END, @detail = CAST(@n AS nvarchar(20)) + N' copy-only full backup(s)';
EXEC dba.usp_Assert 'backup', N'A COPY_ONLY backup was taken before the production deployment', @ok, @detail;
GO

-- The 15-minute log backup job is disabled in the lab, so take the log backup it would have taken.
EXEC dba.usp_BackupDatabase @DatabaseName = N'TransitOps', @BackupType = 'LOG', @Description = N'Test: scheduled log backup';
GO

DECLARE @ok bit, @detail nvarchar(1000), @n bigint;

SELECT @n = COUNT(*),
       @detail = ISNULL(STRING_AGG(CAST(c.DatabaseName + N' ' + c.ComplianceStatus AS nvarchar(max)), N', '), N'all compliant')
FROM dba.vw_BackupCompliance AS c
WHERE c.ComplianceStatus NOT IN ('COMPLIANT', 'EXEMPT');
SELECT @ok = CASE WHEN @n = 0 THEN 1 ELSE 0 END, @detail = LEFT(@detail, 900);
EXEC dba.usp_Assert 'backup', N'Every database meets its backup policy', @ok, @detail;

-- ---------------------------------------------------------------- restore drills
SELECT @ok = 0, @detail = N'no PITR drill logged';
SELECT TOP (1)
       @ok = CASE WHEN d.Status = 'SUCCEEDED' AND d.ValidationStatus = 'PASSED' THEN 1 ELSE 0 END,
       @detail = d.Status + N', validation ' + d.ValidationStatus + N', ' + CAST(d.BackupFilesRestored AS nvarchar(10)) + N' backup files'
FROM dba.RestoreDrillLog AS d
WHERE d.DrillType = 'PITR'
ORDER BY d.DrillId DESC;
EXEC dba.usp_Assert 'recovery', N'Point-in-time recovery reached the right moment and the repair was verified', @ok, @detail;

SELECT @ok = 0, @detail = N'no full-chain drill logged';
SELECT TOP (1)
       @ok = CASE WHEN d.Status = 'SUCCEEDED' AND d.CheckDbStatus = 'CLEAN' AND d.ValidationStatus = 'PASSED' THEN 1 ELSE 0 END,
       @detail = d.Status + N', CHECKDB ' + d.CheckDbStatus + N', row counts ' + d.ValidationStatus
FROM dba.RestoreDrillLog AS d
WHERE d.DrillType = 'FULL_CHAIN'
ORDER BY d.DrillId DESC;
EXEC dba.usp_Assert 'recovery', N'DR drill restored the full chain, CHECKDB clean, row counts match', @ok, @detail;

SELECT @ok = 0, @detail = N'no full-chain drill logged';
SELECT TOP (1)
       @ok = CASE WHEN d.RestoreSeconds <= d.RtoTargetSeconds THEN 1 ELSE 0 END,
       @detail = CAST(d.RestoreSeconds AS nvarchar(10)) + N' s measured against an RTO of ' + CAST(d.RtoTargetSeconds AS nvarchar(10)) + N' s'
FROM dba.RestoreDrillLog AS d
WHERE d.DrillType = 'FULL_CHAIN'
ORDER BY d.DrillId DESC;
EXEC dba.usp_Assert 'recovery', N'Measured recovery time is within the RTO', @ok, @detail;

SELECT @ok = CASE WHEN DB_ID(N'TransitOps_PITR') IS NULL AND DB_ID(N'TransitOps_DRDrill') IS NULL THEN 1 ELSE 0 END, @detail = NULL;
EXEC dba.usp_Assert 'recovery', N'Drill databases were cleaned up', @ok, @detail;

-- ---------------------------------------------------------------- test environment
SELECT @ok = CASE WHEN d.recovery_model_desc = N'SIMPLE' THEN 1 ELSE 0 END,
       @detail = CAST(d.recovery_model_desc AS nvarchar(20))
FROM sys.databases AS d
WHERE d.name = N'TransitOps_TEST';
IF @@ROWCOUNT = 0 SELECT @ok = 0, @detail = N'TransitOps_TEST does not exist';
EXEC dba.usp_Assert 'environments', N'TEST copy exists and is in SIMPLE recovery', @ok, @detail;

SELECT @n = COUNT(*) FROM TransitOps_TEST.ops.Operator AS o WHERE o.Email NOT LIKE '%@test.invalid';
SELECT @ok = CASE WHEN @n = 0 THEN 1 ELSE 0 END, @detail = CAST(@n AS nvarchar(20)) + N' operator rows still carry production e-mail addresses';
EXEC dba.usp_Assert 'environments', N'Personal data is scrubbed in the TEST copy', @ok, @detail;
GO
