/*
    130_restore.sql

    Restore procedures.

      usp_RestoreFromHistory       builds the restore chain (full, latest differential,
                                   every later log) from msdb backup history and runs it,
                                   optionally stopping at a point in time
      usp_RestoreDrill             restores to a side database, measures recovery time
                                   against the RTO, checks integrity, validates row counts
      usp_RefreshLowerEnvironment  rebuilds a TEST copy from production backups and
                                   scrubs personal data before anyone can query it

    A backup that has never been restored is a hope, not a recovery plan. The drill
    procedure exists so that restores are rehearsed on a schedule and the result is logged.
*/
SET NOCOUNT ON;
USE DBAdmin;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dba.usp_RestoreFromHistory
    @SourceDatabase sysname,
    @TargetDatabase sysname,
    @StopAt         datetime2(3) = NULL,   -- NULL = roll forward through every available log backup
    @Execute        bit          = 1,      -- 0 = print the commands only
    @FilesRestored  int          = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @FullId       int,
            @FullUuid     uniqueidentifier,
            @FullLastLsn  numeric(25,0),
            @DbGuid       uniqueidentifier,
            @DiffId       int,
            @DiffLastLsn  numeric(25,0),
            @BaseLastLsn  numeric(25,0),
            @StopLogLsn   numeric(25,0),
            @DataPath     nvarchar(260),
            @LogPath      nvarchar(260),
            @Sep          nchar(1),
            @Move         nvarchar(max),
            @Sql          nvarchar(max),
            @Seq          int,
            @MaxSeq       int,
            @Type         char(1),
            @Path         nvarchar(520),
            @Position     int,
            @Err          int,
            @Rc           int,
            @Gaps         int;

    DECLARE @Chain TABLE (
        Seq          int IDENTITY(1,1) NOT NULL PRIMARY KEY,
        BackupSetId  int            NOT NULL,
        BackupType   char(1)        NOT NULL,
        DevicePath   nvarchar(520)  NOT NULL,
        Position     int            NOT NULL,
        FirstLsn     numeric(25,0)  NOT NULL,
        LastLsn      numeric(25,0)  NOT NULL
    );

    SET @FilesRestored = 0;

    -- ------------------------------------------------------------------ guard rails
    IF @TargetDatabase = @SourceDatabase
    BEGIN
        RAISERROR(N'Refusing to restore over the source database. Restore to a side database and repair or swap deliberately.', 16, 1);
        RETURN 1;
    END;

    -- Only databases named <source>_<suffix> may be replaced, so a typo cannot drop something else.
    IF LEFT(@TargetDatabase, LEN(@SourceDatabase) + 1) <> @SourceDatabase + N'_'
    BEGIN
        RAISERROR(N'Target must be named %s_<suffix> (for example %s_DRDrill).', 16, 1, @SourceDatabase, @SourceDatabase);
        RETURN 1;
    END;

    -- ------------------------------------------------------------------ 1. base full backup
    SELECT TOP (1)
           @FullId      = bs.backup_set_id,
           @FullUuid    = bs.backup_set_uuid,
           @FullLastLsn = bs.last_lsn,
           @DbGuid      = bs.database_guid
    FROM msdb.dbo.backupset AS bs
    WHERE bs.database_name = @SourceDatabase
      AND bs.type = 'D'
      AND bs.is_copy_only = 0
      AND (@StopAt IS NULL OR bs.backup_finish_date <= @StopAt)
    ORDER BY bs.backup_finish_date DESC, bs.backup_set_id DESC;

    IF @FullId IS NULL
    BEGIN
        RAISERROR(N'No usable full backup of %s in msdb history.', 16, 1, @SourceDatabase);
        RETURN 1;
    END;

    -- ------------------------------------------------------------------ 2. latest differential on that base
    SELECT TOP (1)
           @DiffId      = bs.backup_set_id,
           @DiffLastLsn = bs.last_lsn
    FROM msdb.dbo.backupset AS bs
    WHERE bs.database_name = @SourceDatabase
      AND bs.type = 'I'
      AND bs.differential_base_guid = @FullUuid
      AND (@StopAt IS NULL OR bs.backup_finish_date <= @StopAt)
    ORDER BY bs.backup_finish_date DESC, bs.backup_set_id DESC;

    SET @BaseLastLsn = COALESCE(@DiffLastLsn, @FullLastLsn);

    -- ------------------------------------------------------------------ 3. log backups after the base
    -- For a point-in-time restore the chain ends with the first log backup that
    -- started at or after the stop time. A log backup that was already running at
    -- the stop time may have read the log before the stop point was written.
    IF @StopAt IS NOT NULL
    BEGIN
        SELECT TOP (1) @StopLogLsn = bs.last_lsn
        FROM msdb.dbo.backupset AS bs
        WHERE bs.database_name = @SourceDatabase
          AND bs.type = 'L'
          AND bs.database_guid = @DbGuid
          AND bs.last_lsn > @BaseLastLsn
          AND bs.backup_start_date >= @StopAt
        ORDER BY bs.last_lsn ASC;

        IF @StopLogLsn IS NULL
        BEGIN
            RAISERROR(N'No log backup covers the requested point in time. Take a log backup of %s first.', 16, 1, @SourceDatabase);
            RETURN 1;
        END;
    END;

    INSERT @Chain (BackupSetId, BackupType, DevicePath, Position, FirstLsn, LastLsn)
    SELECT bs.backup_set_id, 'D', mf.physical_device_name, bs.position, bs.first_lsn, bs.last_lsn
    FROM msdb.dbo.backupset AS bs
    JOIN msdb.dbo.backupmediafamily AS mf ON mf.media_set_id = bs.media_set_id
    WHERE bs.backup_set_id = @FullId;

    IF @DiffId IS NOT NULL
        INSERT @Chain (BackupSetId, BackupType, DevicePath, Position, FirstLsn, LastLsn)
        SELECT bs.backup_set_id, 'I', mf.physical_device_name, bs.position, bs.first_lsn, bs.last_lsn
        FROM msdb.dbo.backupset AS bs
        JOIN msdb.dbo.backupmediafamily AS mf ON mf.media_set_id = bs.media_set_id
        WHERE bs.backup_set_id = @DiffId;

    INSERT @Chain (BackupSetId, BackupType, DevicePath, Position, FirstLsn, LastLsn)
    SELECT bs.backup_set_id, 'L', mf.physical_device_name, bs.position, bs.first_lsn, bs.last_lsn
    FROM msdb.dbo.backupset AS bs
    JOIN msdb.dbo.backupmediafamily AS mf ON mf.media_set_id = bs.media_set_id
    WHERE bs.database_name = @SourceDatabase
      AND bs.type = 'L'
      AND bs.database_guid = @DbGuid
      AND bs.last_lsn > @BaseLastLsn
      AND (@StopLogLsn IS NULL OR bs.last_lsn <= @StopLogLsn)
    ORDER BY bs.last_lsn ASC;

    -- ------------------------------------------------------------------ 4. the log chain must be unbroken
    -- Each log backup starts exactly where the previous one ended. A gap means a log
    -- backup is missing and nothing after the gap can be restored.
    -- The first log backup in the chain must also reach back to the base backup.
    SELECT @Gaps = COUNT(*)
    FROM (
        SELECT c.FirstLsn,
               LAG(c.LastLsn) OVER (ORDER BY c.Seq) AS PreviousLastLsn
        FROM @Chain AS c
        WHERE c.BackupType = 'L'
    ) AS x
    WHERE (x.PreviousLastLsn IS NOT NULL AND x.FirstLsn <> x.PreviousLastLsn)
       OR (x.PreviousLastLsn IS NULL     AND x.FirstLsn > @BaseLastLsn);

    IF @Gaps > 0
    BEGIN
        RAISERROR(N'The log chain for %s is broken (%d gap(s) in msdb history). Restore is not possible past the gap.', 16, 1, @SourceDatabase, @Gaps);
        RETURN 1;
    END;

    -- ------------------------------------------------------------------ 5. relocate files for the side database
    SET @DataPath = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(260));
    SET @LogPath  = CAST(SERVERPROPERTY('InstanceDefaultLogPath')  AS nvarchar(260));
    SET @Sep      = CASE WHEN @DataPath LIKE N'/%' THEN N'/' ELSE N'\' END;

    IF RIGHT(@DataPath, 1) NOT IN (N'/', N'\') SET @DataPath = @DataPath + @Sep;
    IF RIGHT(@LogPath, 1)  NOT IN (N'/', N'\') SET @LogPath  = @LogPath + @Sep;

    SELECT @Move = STRING_AGG(
               CAST(N'MOVE N''' + REPLACE(bf.logical_name, N'''', N'''''') + N''' TO N'''
                    + CASE WHEN bf.file_type = 'L' THEN @LogPath ELSE @DataPath END
                    + @TargetDatabase + N'_' + bf.logical_name
                    + CASE WHEN bf.file_type = 'L' THEN N'.ldf'
                           WHEN bf.file_number = 1 THEN N'.mdf'
                           ELSE N'.ndf' END
                    + N'''' AS nvarchar(max)), N', ')
    FROM msdb.dbo.backupfile AS bf
    WHERE bf.backup_set_id = @FullId
      AND bf.file_type IN ('D', 'L')
      AND bf.is_present = 1;

    -- ------------------------------------------------------------------ 6. replace an earlier drill copy
    IF @Execute = 1 AND DB_ID(@TargetDatabase) IS NOT NULL
    BEGIN
        IF CAST(DATABASEPROPERTYEX(@TargetDatabase, 'Status') AS nvarchar(60)) = N'ONLINE'
        BEGIN
            SET @Sql = N'ALTER DATABASE ' + QUOTENAME(@TargetDatabase) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;';
            EXEC sys.sp_executesql @Sql;
        END;

        SET @Sql = N'DROP DATABASE ' + QUOTENAME(@TargetDatabase) + N';';
        EXEC sys.sp_executesql @Sql;
    END;

    -- ------------------------------------------------------------------ 7. run the chain
    SELECT @Seq = 1, @MaxSeq = MAX(c.Seq) FROM @Chain AS c;

    WHILE @Seq <= @MaxSeq
    BEGIN
        SELECT @Type = c.BackupType, @Path = c.DevicePath, @Position = c.Position
        FROM @Chain AS c
        WHERE c.Seq = @Seq;

        SET @Sql = CASE WHEN @Type = 'L' THEN N'RESTORE LOG ' ELSE N'RESTORE DATABASE ' END
                 + QUOTENAME(@TargetDatabase)
                 + N' FROM DISK = N''' + REPLACE(@Path, N'''', N'''''') + N''''
                 + N' WITH FILE = ' + CAST(@Position AS nvarchar(10))
                 + N', NORECOVERY, CHECKSUM, STATS = 50'
                 + CASE WHEN @Type = 'D' THEN N', ' + @Move ELSE N'' END
                 + CASE WHEN @Type = 'L' AND @StopAt IS NOT NULL
                        THEN N', STOPAT = ''' + CONVERT(nvarchar(23), @StopAt, 126) + N''''
                        ELSE N'' END
                 + N';';

        PRINT @Sql;

        IF @Execute = 1
        BEGIN
            EXEC @Rc = sys.sp_executesql @Sql;
            SET @Err = @@ERROR;

            IF @Err <> 0 OR @Rc <> 0
            BEGIN
                RAISERROR(N'Restore step %d of %d failed. The target database is left in the RESTORING state for inspection.', 16, 1, @Seq, @MaxSeq);
                RETURN 1;
            END;
        END;

        SET @Seq += 1;
    END;

    -- ------------------------------------------------------------------ 8. recover
    SET @Sql = N'RESTORE DATABASE ' + QUOTENAME(@TargetDatabase) + N' WITH RECOVERY;';
    PRINT @Sql;

    IF @Execute = 1
    BEGIN
        EXEC @Rc = sys.sp_executesql @Sql;
        SET @Err = @@ERROR;

        IF @Err <> 0 OR @Rc <> 0
        BEGIN
            RAISERROR(N'Recovery of %s failed.', 16, 1, @TargetDatabase);
            RETURN 1;
        END;
    END;

    SET @FilesRestored = @MaxSeq;
    RETURN 0;
END;
GO

-- ---------------------------------------------------------------------------
-- Restore drill: prove the backups restore, measure how long it takes, check
-- the restored copy for corruption, and log the outcome.
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dba.usp_RestoreDrill
    @SourceDatabase sysname,
    @TargetDatabase sysname,
    @StopAt         datetime2(3) = NULL,
    @DrillType      varchar(20)  = 'FULL_CHAIN',
    @RunCheckDb     bit          = 1,
    @KeepTarget     bit          = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @DrillId         int,
            @Rc              int,
            @Files           int,
            @Sql             nvarchar(max),
            @Start           datetime2(3) = SYSDATETIME(),
            @RestoreEnd      datetime2(3),
            @LastBackup      datetime,
            @RtoTarget       int,
            @RpoTarget       int,
            @RpoExposure     int,
            @RestoreSeconds  int,
            @SourceRows      bigint,
            @TargetRows      bigint,
            @CheckDb         varchar(12)    = 'SKIPPED',
            @Validation      varchar(12)    = 'NOT RUN',
            @Status          varchar(10)    = 'SUCCEEDED',
            @Notes           nvarchar(1000) = N'';

    SELECT @RtoTarget = p.RtoMinutes * 60,
           @RpoTarget = p.RpoMinutes * 60
    FROM dba.BackupPolicy AS p
    WHERE p.DatabaseName = @SourceDatabase;

    -- RPO exposure: if the source were lost right now, this much work would be gone.
    SELECT @LastBackup = MAX(bs.backup_finish_date)
    FROM msdb.dbo.backupset AS bs
    WHERE bs.database_name = @SourceDatabase
      AND bs.is_copy_only = 0;

    SET @RpoExposure = DATEDIFF(SECOND, @LastBackup, @Start);

    INSERT dba.RestoreDrillLog (DrillType, SourceDatabase, TargetDatabase, StopAt, StartedAt, RtoTargetSeconds, RpoTargetSeconds, RpoExposureSeconds, Status)
    VALUES (@DrillType, @SourceDatabase, @TargetDatabase, @StopAt, @Start, @RtoTarget, @RpoTarget, @RpoExposure, 'RUNNING');

    SET @DrillId = SCOPE_IDENTITY();

    -- ------------------------------------------------------------------ restore
    EXEC @Rc = dba.usp_RestoreFromHistory
         @SourceDatabase = @SourceDatabase,
         @TargetDatabase = @TargetDatabase,
         @StopAt         = @StopAt,
         @FilesRestored  = @Files OUTPUT;

    SET @RestoreEnd     = SYSDATETIME();
    SET @RestoreSeconds = DATEDIFF(SECOND, @Start, @RestoreEnd);

    IF @Rc <> 0 OR ISNULL(CAST(DATABASEPROPERTYEX(@TargetDatabase, 'Status') AS nvarchar(60)), N'MISSING') <> N'ONLINE'
    BEGIN
        UPDATE dba.RestoreDrillLog
        SET RestoreFinishedAt = @RestoreEnd, FinishedAt = SYSDATETIME(), Status = 'FAILED',
            Notes = N'Restore did not complete. See the output of usp_RestoreFromHistory.'
        WHERE DrillId = @DrillId;

        RAISERROR(N'Restore drill failed: %s did not come online.', 16, 1, @TargetDatabase);
        RETURN 1;
    END;

    SET @Notes = CASE WHEN @RtoTarget IS NULL THEN N'No RTO defined in dba.BackupPolicy. '
                      WHEN @RestoreSeconds <= @RtoTarget THEN N'RTO met. '
                      ELSE N'RTO MISSED. ' END
               + CASE WHEN @RpoTarget IS NULL THEN N''
                      WHEN @RpoExposure <= @RpoTarget THEN N'RPO exposure within target. '
                      ELSE N'RPO exposure exceeded target at drill start. ' END;

    -- ------------------------------------------------------------------ integrity
    IF @RunCheckDb = 1
    BEGIN
        SET @Sql = N'DBCC CHECKDB (' + QUOTENAME(@TargetDatabase) + N') WITH NO_INFOMSGS, ALL_ERRORMSGS;';

        BEGIN TRY
            EXEC sys.sp_executesql @Sql;
            SET @CheckDb = 'CLEAN';
        END TRY
        BEGIN CATCH
            SET @CheckDb = 'ERRORS';
            SET @Status  = 'FAILED';
            SET @Notes   = @Notes + N'CHECKDB: ' + LEFT(ERROR_MESSAGE(), 400) + N' ';
        END CATCH;
    END;

    -- ------------------------------------------------------------------ row count validation
    SET @Sql = N'SELECT @Rows = SUM(p.rows) FROM ' + QUOTENAME(@SourceDatabase) + N'.sys.partitions AS p JOIN '
             + QUOTENAME(@SourceDatabase) + N'.sys.objects AS o ON o.object_id = p.object_id '
             + N'WHERE o.type = ''U'' AND o.is_ms_shipped = 0 AND p.index_id IN (0, 1);';
    EXEC sys.sp_executesql @Sql, N'@Rows bigint OUTPUT', @Rows = @SourceRows OUTPUT;

    SET @Sql = REPLACE(@Sql, QUOTENAME(@SourceDatabase) + N'.sys.', QUOTENAME(@TargetDatabase) + N'.sys.');
    EXEC sys.sp_executesql @Sql, N'@Rows bigint OUTPUT', @Rows = @TargetRows OUTPUT;

    IF @StopAt IS NULL
    BEGIN
        -- A full roll-forward should match the source exactly when nothing changed after the last log backup.
        SET @Validation = CASE WHEN @SourceRows = @TargetRows THEN 'PASSED' ELSE 'DIFFERS' END;
        IF @Validation = 'DIFFERS'
            SET @Notes = @Notes + N'Row counts differ: expected only if the source changed after its last log backup. ';
    END
    ELSE
        -- A point-in-time copy is older than the source by design. The scenario script validates it.
        SET @Validation = 'PENDING';

    -- ------------------------------------------------------------------ clean up
    IF @KeepTarget = 0
    BEGIN
        SET @Sql = N'ALTER DATABASE ' + QUOTENAME(@TargetDatabase) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; '
                 + N'DROP DATABASE ' + QUOTENAME(@TargetDatabase) + N';';
        EXEC sys.sp_executesql @Sql;
    END;

    UPDATE dba.RestoreDrillLog
    SET RestoreFinishedAt   = @RestoreEnd,
        FinishedAt          = SYSDATETIME(),
        BackupFilesRestored = @Files,
        RestoreSeconds      = @RestoreSeconds,
        SourceRows          = @SourceRows,
        TargetRows          = @TargetRows,
        CheckDbStatus       = @CheckDb,
        ValidationStatus    = @Validation,
        Status              = @Status,
        Notes               = @Notes
    WHERE DrillId = @DrillId;

    SELECT d.DrillId, d.DrillType, d.TargetDatabase, d.BackupFilesRestored, d.RestoreSeconds,
           d.RtoTargetSeconds, d.RpoExposureSeconds, d.RpoTargetSeconds,
           d.CheckDbStatus, d.ValidationStatus, d.Status, d.Notes
    FROM dba.RestoreDrillLog AS d
    WHERE d.DrillId = @DrillId;

    IF @Status <> 'SUCCEEDED'
    BEGIN
        RAISERROR(N'Restore drill %d finished with status %s.', 16, 1, @DrillId, @Status);
        RETURN 1;
    END;

    RETURN 0;
END;
GO

-- ---------------------------------------------------------------------------
-- Refresh a lower environment from production backups.
-- The copy is scrubbed before the procedure returns. If the scrub procedure is
-- missing or fails, the copy is dropped: an unmasked production copy must never
-- be left where test accounts can reach it.
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dba.usp_RefreshLowerEnvironment
    @SourceDatabase sysname,
    @TargetDatabase sysname
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rc int, @Sql nvarchar(max), @ScrubProc nvarchar(400), @Scrubbed bit = 0;

    EXEC @Rc = dba.usp_RestoreDrill
         @SourceDatabase = @SourceDatabase,
         @TargetDatabase = @TargetDatabase,
         @StopAt         = NULL,
         @DrillType      = 'TEST_REFRESH',
         @RunCheckDb     = 0,
         @KeepTarget     = 1;

    IF @Rc <> 0 RETURN 1;

    -- A test copy does not need point-in-time recovery, and nobody will back up its log.
    SET @Sql = N'ALTER DATABASE ' + QUOTENAME(@TargetDatabase) + N' SET RECOVERY SIMPLE;';
    EXEC sys.sp_executesql @Sql;

    SET @ScrubProc = QUOTENAME(@TargetDatabase) + N'.dbo.usp_ScrubSensitiveData';

    IF OBJECT_ID(@ScrubProc, N'P') IS NOT NULL
    BEGIN
        BEGIN TRY
            EXEC @ScrubProc;
            SET @Scrubbed = 1;
        END TRY
        BEGIN CATCH
            PRINT N'Scrub failed: ' + ERROR_MESSAGE();
        END CATCH;
    END;

    IF @Scrubbed = 0
    BEGIN
        SET @Sql = N'ALTER DATABASE ' + QUOTENAME(@TargetDatabase) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; '
                 + N'DROP DATABASE ' + QUOTENAME(@TargetDatabase) + N';';
        EXEC sys.sp_executesql @Sql;

        RAISERROR(N'%s was dropped because personal data could not be scrubbed.', 16, 1, @TargetDatabase);
        RETURN 1;
    END;

    -- Query Store in the copy still holds production query history. Start clean.
    SET @Sql = N'ALTER DATABASE ' + QUOTENAME(@TargetDatabase) + N' SET QUERY_STORE CLEAR;';
    EXEC sys.sp_executesql @Sql;

    UPDATE d
    SET d.Notes = ISNULL(d.Notes, N'') + N'Recovery set to SIMPLE. Personal data scrubbed. '
    FROM dba.RestoreDrillLog AS d
    WHERE d.DrillId = (SELECT MAX(x.DrillId)
                       FROM dba.RestoreDrillLog AS x
                       WHERE x.DrillType = 'TEST_REFRESH' AND x.TargetDatabase = @TargetDatabase);

    RETURN 0;
END;
GO
