/*
    120_backup.sql

    Backup procedures and the compliance view.

    In production I would deploy a community-standard solution (Ola Hallengren's
    Maintenance Solution) for backups. This lab implements the core mechanics by hand
    on purpose: every option below is a decision a DBA has to be able to explain.

      CHECKSUM      verify page checksums while reading and checksum the backup stream
      COMPRESSION   smaller files, usually faster because of reduced I/O
      VERIFYONLY    proves the file is readable and complete (not that it restores:
                    only a restore drill proves that, see 130_restore.sql)
      COPY_ONLY     an out-of-band full backup that does not reset the differential base
*/
SET NOCOUNT ON;
USE DBAdmin;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dba.usp_BackupDatabase
    @DatabaseName sysname,
    @BackupType   varchar(4),              -- FULL | DIFF | LOG
    @CopyOnly     bit           = 0,
    @Verify       bit           = 1,
    @BackupRoot   nvarchar(260) = NULL,    -- defaults to dba.Config 'BackupRoot'
    @Description  nvarchar(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Root      nvarchar(260),
            @Sep       nchar(1),
            @Dir       nvarchar(400),
            @File      nvarchar(520),
            @Stamp     varchar(30),
            @Sql       nvarchar(max),
            @Recovery  nvarchar(60),
            @LogId     bigint,
            @Err       int,
            @Rc        int,
            @Start     datetime2(3) = SYSDATETIME();

    SET @BackupType = UPPER(@BackupType);

    -- ------------------------------------------------------------------ validation
    IF DB_ID(@DatabaseName) IS NULL
    BEGIN
        RAISERROR(N'Database %s does not exist.', 16, 1, @DatabaseName);
        RETURN 1;
    END;

    IF @BackupType NOT IN ('FULL', 'DIFF', 'LOG')
    BEGIN
        RAISERROR(N'@BackupType must be FULL, DIFF or LOG.', 16, 1);
        RETURN 1;
    END;

    SELECT @Recovery = d.recovery_model_desc
    FROM sys.databases AS d
    WHERE d.name = @DatabaseName;

    IF @BackupType = 'LOG' AND @Recovery = N'SIMPLE'
    BEGIN
        RAISERROR(N'%s is in SIMPLE recovery. Log backups are not possible.', 16, 1, @DatabaseName);
        RETURN 1;
    END;

    IF @BackupType = 'DIFF' AND (@CopyOnly = 1 OR @DatabaseName = N'master')
    BEGIN
        RAISERROR(N'A differential backup cannot be COPY_ONLY and is not supported for master.', 16, 1);
        RETURN 1;
    END;

    -- A differential needs a base. Without a prior full backup the statement fails late; fail early instead.
    IF @BackupType = 'DIFF'
       AND NOT EXISTS (SELECT 1
                       FROM sys.master_files AS mf
                       WHERE mf.database_id = DB_ID(@DatabaseName)
                         AND mf.type = 0
                         AND mf.differential_base_lsn IS NOT NULL)
    BEGIN
        RAISERROR(N'%s has no differential base. Take a FULL backup first.', 16, 1, @DatabaseName);
        RETURN 1;
    END;

    -- In FULL recovery the log chain only starts with the first full backup.
    IF @BackupType = 'LOG'
       AND EXISTS (SELECT 1
                   FROM sys.database_recovery_status AS rs
                   WHERE rs.database_id = DB_ID(@DatabaseName)
                     AND rs.last_log_backup_lsn IS NULL)
    BEGIN
        RAISERROR(N'The log chain for %s has not started. Take a FULL backup first.', 16, 1, @DatabaseName);
        RETURN 1;
    END;

    -- ------------------------------------------------------------------ target path
    SET @Root = COALESCE(NULLIF(@BackupRoot, N''),
                         dba.fn_GetConfig(N'BackupRoot'),
                         CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS nvarchar(260)));

    SET @Sep = CASE WHEN @Root LIKE N'/%' THEN N'/' ELSE N'\' END;
    IF RIGHT(@Root, 1) IN (N'/', N'\') SET @Root = LEFT(@Root, LEN(@Root) - 1);

    -- <root>/<database>/<type>/<database>_<type>_<yyyymmdd_hhmmssmmm>.<ext>
    SET @Dir = @Root + @Sep + REPLACE(@DatabaseName, N' ', N'_') + @Sep + @BackupType;

    BEGIN TRY
        EXEC master.dbo.xp_create_subdir @Dir;
    END TRY
    BEGIN CATCH
        PRINT N'Could not create ' + @Dir + N': ' + ERROR_MESSAGE();
    END CATCH;

    -- If the subfolder could not be created, fall back to a flat layout in the root.
    IF NOT EXISTS (SELECT 1 FROM sys.dm_os_file_exists(@Dir) AS fe WHERE fe.file_is_a_directory = 1)
        SET @Dir = @Root;

    SET @Stamp = REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(varchar(23), @Start, 121), '-', ''), ':', ''), ' ', '_'), '.', '');

    SET @File = @Dir + @Sep + REPLACE(@DatabaseName, N' ', N'_') + N'_' + @BackupType + N'_' + @Stamp
              + CASE @BackupType WHEN 'LOG' THEN N'.trn' WHEN 'DIFF' THEN N'.dif' ELSE N'.bak' END;

    -- ------------------------------------------------------------------ backup
    SET @Sql = CASE WHEN @BackupType = 'LOG' THEN N'BACKUP LOG ' ELSE N'BACKUP DATABASE ' END
             + QUOTENAME(@DatabaseName)
             + N' TO DISK = N''' + REPLACE(@File, N'''', N'''''') + N''''
             + N' WITH '
             + CASE WHEN @BackupType = 'DIFF' THEN N'DIFFERENTIAL, ' ELSE N'' END
             + CASE WHEN @CopyOnly = 1 THEN N'COPY_ONLY, ' ELSE N'' END
             + N'COMPRESSION, CHECKSUM, INIT, STATS = 50, NAME = N'''
             + REPLACE(@DatabaseName, N'''', N'''''') + N' ' + @BackupType + N' ' + @Stamp + N''';';

    INSERT dba.BackupLog (DatabaseName, BackupType, IsCopyOnly, FilePath, StartedAt, Status, Description)
    VALUES (@DatabaseName, @BackupType, @CopyOnly, @File, @Start, 'RUNNING', @Description);

    SET @LogId = SCOPE_IDENTITY();

    -- No TRY/CATCH around BACKUP on purpose: a failed backup raises two errors
    -- (the real cause, then "BACKUP DATABASE is terminating abnormally") and CATCH
    -- would only see the second. Letting both reach the caller keeps the cause visible.
    EXEC @Rc = sys.sp_executesql @Sql;
    SET @Err = @@ERROR;

    IF @Err <> 0 OR @Rc <> 0
    BEGIN
        UPDATE dba.BackupLog
        SET FinishedAt = SYSDATETIME(), Status = 'FAILED',
            ErrorMessage = N'BACKUP failed with error ' + CAST(COALESCE(NULLIF(@Err, 0), @Rc) AS nvarchar(12)) + N'. See the SQL Server error log.'
        WHERE BackupLogId = @LogId;

        RAISERROR(N'Backup of %s (%s) failed.', 16, 1, @DatabaseName, @BackupType);
        RETURN 1;
    END;

    -- ------------------------------------------------------------------ verify
    IF @Verify = 1
    BEGIN
        SET @Sql = N'RESTORE VERIFYONLY FROM DISK = N''' + REPLACE(@File, N'''', N'''''') + N''' WITH CHECKSUM;';

        EXEC @Rc = sys.sp_executesql @Sql;
        SET @Err = @@ERROR;

        IF @Err <> 0 OR @Rc <> 0
        BEGIN
            UPDATE dba.BackupLog
            SET FinishedAt = SYSDATETIME(), Status = 'FAILED',
                ErrorMessage = N'Backup was written but RESTORE VERIFYONLY failed. Treat the file as unusable.'
            WHERE BackupLogId = @LogId;

            RAISERROR(N'Verification of the %s backup of %s failed.', 16, 1, @BackupType, @DatabaseName);
            RETURN 1;
        END;
    END;

    -- ------------------------------------------------------------------ log the result
    UPDATE l
    SET l.FinishedAt       = SYSDATETIME(),
        l.Status           = 'SUCCEEDED',
        l.Verified         = @Verify,
        l.SizeMB           = b.backup_size / 1048576.0,
        l.CompressedSizeMB = b.compressed_backup_size / 1048576.0
    FROM dba.BackupLog AS l
    OUTER APPLY (
        SELECT TOP (1) bs.backup_size, bs.compressed_backup_size
        FROM msdb.dbo.backupset AS bs
        JOIN msdb.dbo.backupmediafamily AS mf ON mf.media_set_id = bs.media_set_id
        WHERE mf.physical_device_name = @File
        ORDER BY bs.backup_set_id DESC
    ) AS b
    WHERE l.BackupLogId = @LogId;

    RETURN 0;
END;
GO

-- ---------------------------------------------------------------------------
-- Back up every database that the policy says needs this backup type.
-- This is what the Agent jobs call.
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dba.usp_BackupPerPolicy
    @BackupType varchar(4)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Db sysname, @Rc int, @Failures int = 0;

    SET @BackupType = UPPER(@BackupType);

    DECLARE PolicyDatabases CURSOR LOCAL FAST_FORWARD FOR
        SELECT p.DatabaseName
        FROM dba.BackupPolicy AS p
        JOIN sys.databases AS d ON d.name = p.DatabaseName COLLATE DATABASE_DEFAULT
        WHERE d.state_desc = N'ONLINE'
          AND (   (@BackupType = 'FULL' AND p.FullEveryHours IS NOT NULL)
               OR (@BackupType = 'DIFF' AND p.DiffEveryHours IS NOT NULL)
               OR (@BackupType = 'LOG'  AND p.LogEveryMinutes IS NOT NULL AND d.recovery_model_desc <> N'SIMPLE'))
        ORDER BY p.DatabaseName;

    OPEN PolicyDatabases;
    FETCH NEXT FROM PolicyDatabases INTO @Db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC @Rc = dba.usp_BackupDatabase @DatabaseName = @Db, @BackupType = @BackupType;
        IF @Rc <> 0 SET @Failures += 1;

        FETCH NEXT FROM PolicyDatabases INTO @Db;
    END;

    CLOSE PolicyDatabases;
    DEALLOCATE PolicyDatabases;

    IF @Failures > 0
    BEGIN
        RAISERROR(N'%d backup(s) failed. See dba.BackupLog.', 16, 1, @Failures);
        RETURN 1;
    END;

    RETURN 0;
END;
GO

-- ---------------------------------------------------------------------------
-- Policy compliance: is every database backed up as often as its policy requires?
-- Reads msdb backup history, so it also sees backups taken outside this toolkit.
-- ---------------------------------------------------------------------------
CREATE OR ALTER VIEW dba.vw_BackupCompliance
AS
SELECT  p.DatabaseName,
        p.Tier,
        p.RecoveryModel                              AS PolicyRecoveryModel,
        CAST(d.recovery_model_desc AS varchar(12)) COLLATE DATABASE_DEFAULT AS ActualRecoveryModel,
        b.LastFull,
        b.LastDiff,
        b.LastLog,
        DATEDIFF(MINUTE, b.LastFull, GETDATE())      AS FullAgeMinutes,
        DATEDIFF(MINUTE, b.LastLog,  GETDATE())      AS LogAgeMinutes,
        p.RpoMinutes,
        CAST(CASE
                 WHEN d.database_id IS NULL                                                   THEN 'DATABASE MISSING'
                 WHEN d.recovery_model_desc COLLATE DATABASE_DEFAULT <> p.RecoveryModel       THEN 'RECOVERY MODEL DRIFT'
                 WHEN p.FullEveryHours IS NULL                                                THEN 'EXEMPT'
                 WHEN b.LastFull IS NULL                                                      THEN 'NO FULL BACKUP'
                 WHEN DATEDIFF(MINUTE, b.LastFull, GETDATE()) > p.FullEveryHours * 60         THEN 'FULL OVERDUE'
                 WHEN p.LogEveryMinutes IS NOT NULL AND b.LastLog IS NULL                     THEN 'NO LOG BACKUP'
                 WHEN p.LogEveryMinutes IS NOT NULL
                      AND DATEDIFF(MINUTE, b.LastLog, GETDATE()) > p.RpoMinutes               THEN 'RPO AT RISK'
                 ELSE 'COMPLIANT'
             END AS varchar(24))                     AS ComplianceStatus
FROM dba.BackupPolicy AS p
LEFT JOIN sys.databases AS d
       ON d.name = p.DatabaseName COLLATE DATABASE_DEFAULT
OUTER APPLY (
    SELECT MAX(CASE WHEN bs.type = 'D' AND bs.is_copy_only = 0 THEN bs.backup_finish_date END) AS LastFull,
           MAX(CASE WHEN bs.type = 'I' THEN bs.backup_finish_date END)                         AS LastDiff,
           MAX(CASE WHEN bs.type = 'L' THEN bs.backup_finish_date END)                         AS LastLog
    FROM msdb.dbo.backupset AS bs
    WHERE bs.database_name = p.DatabaseName COLLATE DATABASE_DEFAULT
) AS b;
GO
