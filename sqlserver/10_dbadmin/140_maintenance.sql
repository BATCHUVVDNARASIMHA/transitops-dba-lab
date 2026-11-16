/*
    140_maintenance.sql

    Routine maintenance: integrity checks, index and statistics maintenance, and
    history purging. Every action is written to a log table with its command text,
    so "what changed last night?" has an answer.
*/
SET NOCOUNT ON;
USE DBAdmin;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ---------------------------------------------------------------------------
-- DBCC CHECKDB for one database, or for every database in the backup policy.
-- Corruption found here is still fixable from backups. Corruption found by a
-- user six months later usually is not.
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dba.usp_IntegrityCheck
    @DatabaseName sysname = NULL,
    @PhysicalOnly bit     = 0      -- 1 = faster check for very large databases between full checks
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Db       sysname,
            @Sql      nvarchar(max),
            @Start    datetime2(3),
            @Status   varchar(10),
            @Message  nvarchar(2048),
            @Failures int = 0;

    DECLARE CheckDatabases CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.state_desc = N'ONLINE'
          AND d.name <> N'tempdb'
          AND (   d.name = @DatabaseName
               OR (@DatabaseName IS NULL
                   AND EXISTS (SELECT 1 FROM dba.BackupPolicy AS p WHERE p.DatabaseName = d.name COLLATE DATABASE_DEFAULT)))
        ORDER BY d.name;

    OPEN CheckDatabases;
    FETCH NEXT FROM CheckDatabases INTO @Db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @Start = SYSDATETIME(), @Status = 'CLEAN', @Message = NULL;

        SET @Sql = N'DBCC CHECKDB (' + QUOTENAME(@Db) + N') WITH NO_INFOMSGS, ALL_ERRORMSGS'
                 + CASE WHEN @PhysicalOnly = 1 THEN N', PHYSICAL_ONLY' ELSE N'' END + N';';

        BEGIN TRY
            EXEC sys.sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            SELECT @Status = 'ERRORS', @Message = ERROR_MESSAGE(), @Failures += 1;
        END CATCH;

        INSERT dba.IntegrityCheckLog (DatabaseName, PhysicalOnly, StartedAt, FinishedAt, Status, LastGoodCheckDb, ErrorMessage)
        VALUES (@Db, @PhysicalOnly, @Start, SYSDATETIME(), @Status,
                CAST(DATABASEPROPERTYEX(@Db, 'LastGoodCheckDbTime') AS datetime), @Message);

        FETCH NEXT FROM CheckDatabases INTO @Db;
    END;

    CLOSE CheckDatabases;
    DEALLOCATE CheckDatabases;

    IF @Failures > 0
    BEGIN
        RAISERROR(N'CHECKDB reported errors in %d database(s). See dba.IntegrityCheckLog and docs/runbooks/SOP-02-incident-triage.md.', 16, 1, @Failures);
        RETURN 1;
    END;

    RETURN 0;
END;
GO

-- ---------------------------------------------------------------------------
-- Index maintenance driven by measured fragmentation.
--   5 to 30 percent : REORGANIZE (always online, can be interrupted)
--   over 30 percent : REBUILD (ONLINE where the edition supports it)
-- Small indexes are skipped: fragmentation on a few hundred pages does not matter.
-- Partitioned indexes are maintained one partition at a time.
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dba.usp_IndexMaintenance
    @DatabaseName      sysname,
    @ReorganizeFromPct float = 5.0,
    @RebuildFromPct    float = 30.0,
    @MinPageCount      int   = 1000,
    @Execute           bit   = 1
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @DbId          int = DB_ID(@DatabaseName),
            @OnlineOk      bit = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 3 THEN 1 ELSE 0 END,
            @Sql           nvarchar(max),
            @Cmd           nvarchar(2000),
            @Id            int,
            @ObjectId      int,
            @IndexId       int,
            @Schema        sysname,
            @Table         sysname,
            @Index         sysname,
            @Partition     int,
            @IsPartitioned bit,
            @Frag          float,
            @FragAfter     float,
            @Pages         bigint,
            @Action        varchar(12),
            @Start         datetime2(3),
            @ErrNo         int,
            @ErrMsg        nvarchar(2048),
            @Errors        int = 0;

    IF @DbId IS NULL
    BEGIN
        RAISERROR(N'Database %s does not exist.', 16, 1, @DatabaseName);
        RETURN 1;
    END;

    CREATE TABLE #Work (
        Id                int IDENTITY(1,1) NOT NULL PRIMARY KEY,
        ObjectId          int      NOT NULL,
        IndexId           int      NOT NULL,
        SchemaName        sysname  COLLATE DATABASE_DEFAULT NOT NULL,
        TableName         sysname  COLLATE DATABASE_DEFAULT NOT NULL,
        IndexName         sysname  COLLATE DATABASE_DEFAULT NOT NULL,
        PartitionNumber   int      NOT NULL,
        IsPartitioned     bit      NOT NULL,
        FragmentationPct  float    NOT NULL,
        PageCount         bigint   NOT NULL,
        Action            varchar(12) COLLATE DATABASE_DEFAULT NOT NULL
    );

    SET @Sql = N'USE ' + QUOTENAME(@DatabaseName) + N';
        SELECT i.object_id, i.index_id, s.name, o.name, i.name, ps.partition_number,
               CASE WHEN ds.type = ''PS'' THEN 1 ELSE 0 END,
               ps.avg_fragmentation_in_percent, ps.page_count,
               CASE WHEN ps.avg_fragmentation_in_percent >= @RebuildFromPct THEN ''REBUILD'' ELSE ''REORGANIZE'' END
        FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, ''LIMITED'') AS ps
        JOIN sys.indexes     AS i  ON i.object_id = ps.object_id AND i.index_id = ps.index_id
        JOIN sys.objects     AS o  ON o.object_id = i.object_id
        JOIN sys.schemas     AS s  ON s.schema_id = o.schema_id
        JOIN sys.data_spaces AS ds ON ds.data_space_id = i.data_space_id
        WHERE ps.index_id > 0
          AND ps.alloc_unit_type_desc = ''IN_ROW_DATA''
          AND o.is_ms_shipped = 0
          AND i.is_disabled = 0
          AND i.is_hypothetical = 0
          AND ps.page_count >= @MinPageCount
          AND ps.avg_fragmentation_in_percent >= @ReorganizeFromPct
        ORDER BY ps.page_count DESC;';

    INSERT #Work (ObjectId, IndexId, SchemaName, TableName, IndexName, PartitionNumber, IsPartitioned, FragmentationPct, PageCount, Action)
    EXEC sys.sp_executesql @Sql,
         N'@RebuildFromPct float, @ReorganizeFromPct float, @MinPageCount int',
         @RebuildFromPct = @RebuildFromPct, @ReorganizeFromPct = @ReorganizeFromPct, @MinPageCount = @MinPageCount;

    DECLARE WorkItems CURSOR LOCAL FAST_FORWARD FOR
        SELECT w.Id, w.ObjectId, w.IndexId, w.SchemaName, w.TableName, w.IndexName, w.PartitionNumber,
               w.IsPartitioned, w.FragmentationPct, w.PageCount, w.Action
        FROM #Work AS w
        ORDER BY w.Id;

    OPEN WorkItems;
    FETCH NEXT FROM WorkItems INTO @Id, @ObjectId, @IndexId, @Schema, @Table, @Index, @Partition, @IsPartitioned, @Frag, @Pages, @Action;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Cmd = N'USE ' + QUOTENAME(@DatabaseName) + N'; ALTER INDEX ' + QUOTENAME(@Index)
                 + N' ON ' + QUOTENAME(@Schema) + N'.' + QUOTENAME(@Table)
                 + CASE WHEN @Action = 'REBUILD' THEN N' REBUILD' ELSE N' REORGANIZE' END
                 + CASE WHEN @IsPartitioned = 1 THEN N' PARTITION = ' + CAST(@Partition AS nvarchar(10)) ELSE N'' END
                 + CASE WHEN @Action = 'REBUILD' AND @OnlineOk = 1 THEN N' WITH (ONLINE = ON)' ELSE N'' END
                 + N';';

        SELECT @Start = SYSDATETIME(), @ErrNo = NULL, @ErrMsg = NULL, @FragAfter = NULL;

        IF @Execute = 1
        BEGIN
            BEGIN TRY
                EXEC sys.sp_executesql @Cmd;
            END TRY
            BEGIN CATCH
                SELECT @ErrNo = ERROR_NUMBER(), @ErrMsg = ERROR_MESSAGE();
            END CATCH;

            -- Some indexes cannot be rebuilt online. Retry offline instead of skipping them.
            IF @ErrNo IS NOT NULL AND @Cmd LIKE N'%ONLINE = ON%'
            BEGIN
                SET @Cmd = REPLACE(@Cmd, N' WITH (ONLINE = ON)', N'');
                SELECT @ErrNo = NULL, @ErrMsg = NULL;

                BEGIN TRY
                    EXEC sys.sp_executesql @Cmd;
                END TRY
                BEGIN CATCH
                    SELECT @ErrNo = ERROR_NUMBER(), @ErrMsg = ERROR_MESSAGE();
                END CATCH;
            END;

            IF @ErrNo IS NULL
                SELECT @FragAfter = MAX(ps.avg_fragmentation_in_percent)
                FROM sys.dm_db_index_physical_stats(@DbId, @ObjectId, @IndexId, @Partition, 'LIMITED') AS ps
                WHERE ps.alloc_unit_type_desc = 'IN_ROW_DATA';
            ELSE
                SET @Errors += 1;
        END;

        INSERT dba.MaintenanceLog (DatabaseName, ObjectName, IndexOrStatName, PartitionNumber, Operation, Command,
                                   PageCount, FragmentationBefore, FragmentationAfter, StartedAt, FinishedAt, ErrorNumber, ErrorMessage)
        VALUES (@DatabaseName, @Schema + N'.' + @Table, @Index, @Partition,
                CASE WHEN @Execute = 1 THEN @Action ELSE 'PLANNED' END, @Cmd,
                @Pages, @Frag, @FragAfter, @Start, SYSDATETIME(), @ErrNo, @ErrMsg);

        FETCH NEXT FROM WorkItems INTO @Id, @ObjectId, @IndexId, @Schema, @Table, @Index, @Partition, @IsPartitioned, @Frag, @Pages, @Action;
    END;

    CLOSE WorkItems;
    DEALLOCATE WorkItems;

    IF @Errors > 0
    BEGIN
        RAISERROR(N'%d index operation(s) failed in %s. See dba.MaintenanceLog.', 16, 1, @Errors, @DatabaseName);
        RETURN 1;
    END;

    RETURN 0;
END;
GO

-- ---------------------------------------------------------------------------
-- Statistics maintenance driven by the modification counter.
-- Auto-update statistics fires late on large tables; this closes the gap.
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dba.usp_UpdateStatistics
    @DatabaseName      sysname,
    @ModifiedPct       float  = 5.0,
    @MinModifications  bigint = 1000,
    @FullScan          bit    = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Sql     nvarchar(max),
            @Cmd     nvarchar(2000),
            @Schema  sysname,
            @Table   sysname,
            @Stat    sysname,
            @Start   datetime2(3),
            @ErrNo   int,
            @ErrMsg  nvarchar(2048),
            @Errors  int = 0;

    IF DB_ID(@DatabaseName) IS NULL
    BEGIN
        RAISERROR(N'Database %s does not exist.', 16, 1, @DatabaseName);
        RETURN 1;
    END;

    CREATE TABLE #Stats (
        SchemaName  sysname COLLATE DATABASE_DEFAULT NOT NULL,
        TableName   sysname COLLATE DATABASE_DEFAULT NOT NULL,
        StatName    sysname COLLATE DATABASE_DEFAULT NOT NULL
    );

    SET @Sql = N'USE ' + QUOTENAME(@DatabaseName) + N';
        SELECT s.name, o.name, st.name
        FROM sys.stats AS st
        JOIN sys.objects AS o ON o.object_id = st.object_id
        JOIN sys.schemas AS s ON s.schema_id = o.schema_id
        CROSS APPLY sys.dm_db_stats_properties(st.object_id, st.stats_id) AS sp
        WHERE o.type = ''U''
          AND o.is_ms_shipped = 0
          AND sp.modification_counter >= @MinModifications
          AND (sp.rows = 0 OR sp.modification_counter * 100.0 / NULLIF(sp.rows, 0) >= @ModifiedPct);';

    INSERT #Stats (SchemaName, TableName, StatName)
    EXEC sys.sp_executesql @Sql, N'@MinModifications bigint, @ModifiedPct float',
         @MinModifications = @MinModifications, @ModifiedPct = @ModifiedPct;

    DECLARE StatItems CURSOR LOCAL FAST_FORWARD FOR
        SELECT x.SchemaName, x.TableName, x.StatName FROM #Stats AS x ORDER BY x.SchemaName, x.TableName, x.StatName;

    OPEN StatItems;
    FETCH NEXT FROM StatItems INTO @Schema, @Table, @Stat;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Cmd = N'USE ' + QUOTENAME(@DatabaseName) + N'; UPDATE STATISTICS ' + QUOTENAME(@Schema) + N'.' + QUOTENAME(@Table)
                 + N' (' + QUOTENAME(@Stat) + N')'
                 + CASE WHEN @FullScan = 1 THEN N' WITH FULLSCAN' ELSE N'' END + N';';

        SELECT @Start = SYSDATETIME(), @ErrNo = NULL, @ErrMsg = NULL;

        BEGIN TRY
            EXEC sys.sp_executesql @Cmd;
        END TRY
        BEGIN CATCH
            SELECT @ErrNo = ERROR_NUMBER(), @ErrMsg = ERROR_MESSAGE(), @Errors += 1;
        END CATCH;

        INSERT dba.MaintenanceLog (DatabaseName, ObjectName, IndexOrStatName, Operation, Command, StartedAt, FinishedAt, ErrorNumber, ErrorMessage)
        VALUES (@DatabaseName, @Schema + N'.' + @Table, @Stat, 'UPDATE STATS', @Cmd, @Start, SYSDATETIME(), @ErrNo, @ErrMsg);

        FETCH NEXT FROM StatItems INTO @Schema, @Table, @Stat;
    END;

    CLOSE StatItems;
    DEALLOCATE StatItems;

    IF @Errors > 0
    BEGIN
        RAISERROR(N'%d statistics update(s) failed in %s. See dba.MaintenanceLog.', 16, 1, @Errors, @DatabaseName);
        RETURN 1;
    END;

    RETURN 0;
END;
GO

-- ---------------------------------------------------------------------------
-- Purge history: msdb backup and job history, DBAdmin run logs, and optionally
-- backup files past their retention period.
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dba.usp_PurgeHistory
    @RetentionDays     int = 30,
    @PurgeBackupFiles  bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Cutoff      datetime = DATEADD(DAY, -@RetentionDays, GETDATE()),
            @Root        nvarchar(260) = dba.fn_GetConfig(N'BackupRoot'),
            @Sep         nchar(1),
            @Db          sysname,
            @Dir         nvarchar(400),
            @FileCutoff  nvarchar(19),
            @Days        int;

    EXEC msdb.dbo.sp_delete_backuphistory @oldest_date = @Cutoff;
    EXEC msdb.dbo.sp_purge_jobhistory @oldest_date = @Cutoff;

    DELETE FROM dba.BackupLog          WHERE StartedAt  < @Cutoff;
    DELETE FROM dba.MaintenanceLog     WHERE StartedAt  < @Cutoff;
    DELETE FROM dba.IntegrityCheckLog  WHERE StartedAt  < @Cutoff;
    DELETE FROM dba.HealthCheckResult  WHERE CheckedAt  < @Cutoff;
    DELETE FROM dba.BlockingSnapshot   WHERE CapturedAt < @Cutoff;
    DELETE FROM dba.WaitStatsSnapshot  WHERE CapturedAt < @Cutoff;
    -- dba.RestoreDrillLog and dba.DatabaseSizeHistory are kept: they are evidence and trend data.

    IF @PurgeBackupFiles = 1 AND @Root IS NOT NULL
    BEGIN
        SET @Sep = CASE WHEN @Root LIKE N'/%' THEN N'/' ELSE N'\' END;
        IF RIGHT(@Root, 1) IN (N'/', N'\') SET @Root = LEFT(@Root, LEN(@Root) - 1);

        DECLARE RetentionPolicies CURSOR LOCAL FAST_FORWARD FOR
            SELECT p.DatabaseName, p.RetentionDays
            FROM dba.BackupPolicy AS p
            WHERE p.FullEveryHours IS NOT NULL AND p.RetentionDays > 0;

        OPEN RetentionPolicies;
        FETCH NEXT FROM RetentionPolicies INTO @Db, @Days;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @Dir        = @Root + @Sep + REPLACE(@Db, N' ', N'_');
            SET @FileCutoff = CONVERT(nvarchar(19), DATEADD(DAY, -@Days, GETDATE()), 126);

            -- xp_delete_file only removes genuine SQL Server backup files with the given
            -- extension, older than the cutoff, in the folder and its first-level subfolders.
            BEGIN TRY
                EXEC master.dbo.xp_delete_file 0, @Dir, N'bak', @FileCutoff, 1;
                EXEC master.dbo.xp_delete_file 0, @Dir, N'dif', @FileCutoff, 1;
                EXEC master.dbo.xp_delete_file 0, @Dir, N'trn', @FileCutoff, 1;
            END TRY
            BEGIN CATCH
                PRINT N'Backup file purge skipped for ' + @Db + N': ' + ERROR_MESSAGE();
            END CATCH;

            FETCH NEXT FROM RetentionPolicies INTO @Db, @Days;
        END;

        CLOSE RetentionPolicies;
        DEALLOCATE RetentionPolicies;
    END;
END;
GO
