/*
    240_programmability.sql

    Indexes, reporting views, the application's stored procedure interface, and
    the operational procedures the DBA runs against this database:

      fare.usp_AddTapPartition      add next month's partition (metadata-only split)
      fare.usp_ArchiveTapMonth      move one month from fare.Tap to fare.TapArchive
      dbo.usp_PartitionReport       rows and size per partition
      dbo.usp_ScrubSensitiveData    replace personal data in a non-production copy
      dbo.usp_GenerateWorkload      simulate application activity between backups
*/
SET NOCOUNT ON;
USE TransitOps;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ---------------------------------------------------------------------------
-- Baseline indexes. fare.Tap deliberately starts with only its clustered key:
-- the performance labs add indexes one at a time and measure each change.
-- ---------------------------------------------------------------------------
CREATE NONCLUSTERED INDEX IX_Trip_ServiceDate_RouteId
    ON ops.Trip (ServiceDate, RouteId)
    INCLUDE (Status, ScheduledStart, ActualStart);

CREATE NONCLUSTERED INDEX IX_Trip_VehicleId
    ON ops.Trip (VehicleId);

CREATE NONCLUSTERED INDEX IX_WorkOrder_VehicleId
    ON maint.WorkOrder (VehicleId);

-- Filtered index: nine out of ten work orders are closed and never searched by status.
CREATE NONCLUSTERED INDEX IX_WorkOrder_Open
    ON maint.WorkOrder (GarageId, Priority)
    INCLUDE (VehicleId, OpenedAt, Status)
    WHERE Status <> 'CLOSED';

CREATE NONCLUSTERED INDEX IX_WorkOrderTask_WorkOrderId
    ON maint.WorkOrderTask (WorkOrderId);
GO

-- ---------------------------------------------------------------------------
-- Reporting views. The reporting role gets SELECT on this schema only.
-- ---------------------------------------------------------------------------
CREATE OR ALTER VIEW rpt.vw_DailyRidership
AS
SELECT CAST(t.TapDateTime AS date) AS ServiceDate,
       s.StopId,
       s.StopName,
       s.IsStation,
       COUNT_BIG(*)                AS Taps,
       SUM(t.Amount)               AS FareRevenue
FROM fare.Tap AS t
JOIN ref.Stop AS s ON s.StopId = t.StopId
GROUP BY CAST(t.TapDateTime AS date), s.StopId, s.StopName, s.IsStation;
GO

CREATE OR ALTER VIEW rpt.vw_RouteOnTimePerformance
AS
SELECT tr.ServiceDate,
       r.RouteCode,
       r.RouteName,
       COUNT(*)                                                    AS Trips,
       SUM(CASE WHEN tr.Status = 'CANCELLED' THEN 1 ELSE 0 END)    AS CancelledTrips,
       CAST(100.0 * SUM(CASE WHEN tr.Status = 'COMPLETED' AND DATEDIFF(MINUTE, tr.ScheduledStart, tr.ActualStart) <= 5 THEN 1 ELSE 0 END)
            / NULLIF(SUM(CASE WHEN tr.Status = 'COMPLETED' THEN 1 ELSE 0 END), 0) AS decimal(5,1)) AS OnTimePercent
FROM ops.Trip AS tr
JOIN ref.Route AS r ON r.RouteId = tr.RouteId
GROUP BY tr.ServiceDate, r.RouteCode, r.RouteName;
GO

CREATE OR ALTER VIEW rpt.vw_FleetAvailability
AS
SELECT g.GarageName,
       m.ModeName,
       COUNT(*)                                                AS Vehicles,
       SUM(CASE WHEN v.Status = 'ACTIVE'  THEN 1 ELSE 0 END)   AS Active,
       SUM(CASE WHEN v.Status = 'IN_SHOP' THEN 1 ELSE 0 END)   AS InShop,
       SUM(CASE WHEN v.Status = 'RETIRED' THEN 1 ELSE 0 END)   AS Retired
FROM ops.Vehicle AS v
JOIN ref.Garage AS g ON g.GarageId = v.GarageId
JOIN ref.Mode   AS m ON m.ModeId = v.ModeId
GROUP BY g.GarageName, m.ModeName;
GO

CREATE OR ALTER VIEW rpt.vw_OpenWorkOrders
AS
SELECT w.WorkOrderId,
       g.GarageName,
       v.FleetNumber,
       w.Category,
       w.Priority,
       w.Status,
       w.OpenedAt
FROM maint.WorkOrder AS w
JOIN ops.Vehicle AS v ON v.VehicleId = w.VehicleId
JOIN ref.Garage  AS g ON g.GarageId = w.GarageId
WHERE w.Status <> 'CLOSED';
GO

-- ---------------------------------------------------------------------------
-- Application interface. The service account can execute these procedures and
-- has no permission on the tables: ownership chaining does the rest.
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE app.usp_RecordTap
    @CardId         int,
    @StopId         int,
    @FareProductId  smallint,
    @TapType        char(1)      = 'E',
    @TapDateTime    datetime2(0) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    INSERT fare.Tap (TapDateTime, CardId, StopId, FareProductId, Amount, TapType)
    SELECT ISNULL(@TapDateTime, SYSDATETIME()), @CardId, @StopId, fp.FareProductId, fp.Price, @TapType
    FROM fare.FareProduct AS fp
    WHERE fp.FareProductId = @FareProductId;

    IF @@ROWCOUNT = 0
        THROW 50100, 'Unknown fare product.', 1;
END;
GO

CREATE OR ALTER PROCEDURE app.usp_GetVehicleStatus
    @FleetNumber varchar(10)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT v.VehicleId, v.FleetNumber, v.Status, v.LastModified, g.GarageName
    FROM ops.Vehicle AS v
    JOIN ref.Garage AS g ON g.GarageId = v.GarageId
    WHERE v.FleetNumber = @FleetNumber;
END;
GO

-- The two procedures below both change a vehicle and a work order. They take
-- their locks in the same order (Vehicle first, then WorkOrder) and retry if
-- chosen as a deadlock victim. Performance lab 6 shows what happens when two
-- code paths take the same locks in opposite orders.
-- @HoldSeconds exists only so the lab can force the two calls to overlap.
CREATE OR ALTER PROCEDURE app.usp_CloseWorkOrder
    @WorkOrderId  int,
    @HoldSeconds  tinyint = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @VehicleId int,
            @Attempt   tinyint = 1,
            @Delay     char(8) = '00:00:' + RIGHT('0' + CAST(CASE WHEN @HoldSeconds > 59 THEN 59 ELSE @HoldSeconds END AS varchar(2)), 2);

    SELECT @VehicleId = w.VehicleId
    FROM maint.WorkOrder AS w
    WHERE w.WorkOrderId = @WorkOrderId;

    IF @VehicleId IS NULL
        THROW 50101, 'Work order not found.', 1;

    WHILE @Attempt <= 3
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            UPDATE ops.Vehicle
            SET Status = 'ACTIVE', LastModified = SYSDATETIME()
            WHERE VehicleId = @VehicleId;

            IF @HoldSeconds > 0 WAITFOR DELAY @Delay;

            UPDATE maint.WorkOrder
            SET Status = 'CLOSED', ClosedAt = SYSDATETIME()
            WHERE WorkOrderId = @WorkOrderId;

            COMMIT TRANSACTION;
            RETURN 0;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            -- Anything other than a deadlock, or a third failed attempt, goes back to the caller.
            IF ERROR_NUMBER() <> 1205 OR @Attempt >= 3
                THROW;

            SET @Attempt += 1;
            WAITFOR DELAY '00:00:00.250';
        END CATCH;
    END;
END;
GO

CREATE OR ALTER PROCEDURE app.usp_PullVehicleFromService
    @VehicleId    int,
    @WorkOrderId  int,
    @HoldSeconds  tinyint = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Attempt tinyint = 1,
            @Delay   char(8) = '00:00:' + RIGHT('0' + CAST(CASE WHEN @HoldSeconds > 59 THEN 59 ELSE @HoldSeconds END AS varchar(2)), 2);

    WHILE @Attempt <= 3
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            UPDATE ops.Vehicle
            SET Status = 'IN_SHOP', LastModified = SYSDATETIME()
            WHERE VehicleId = @VehicleId;

            IF @HoldSeconds > 0 WAITFOR DELAY @Delay;

            UPDATE maint.WorkOrder
            SET Status = 'IN_PROGRESS', Priority = 1, ClosedAt = NULL
            WHERE WorkOrderId = @WorkOrderId;

            COMMIT TRANSACTION;
            RETURN 0;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            -- Anything other than a deadlock, or a third failed attempt, goes back to the caller.
            IF ERROR_NUMBER() <> 1205 OR @Attempt >= 3
                THROW;

            SET @Attempt += 1;
            WAITFOR DELAY '00:00:00.250';
        END CATCH;
    END;
END;
GO

-- ---------------------------------------------------------------------------
-- Partition management
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_PartitionReport
AS
BEGIN
    SET NOCOUNT ON;

    SELECT CAST(OBJECT_SCHEMA_NAME(p.object_id) + N'.' + OBJECT_NAME(p.object_id) AS nvarchar(20)) AS TableName,
           p.partition_number                                                    AS PartitionNumber,
           CONVERT(char(10), CAST(prv.value AS datetime2(0)), 120)               AS LowerBoundInclusive,
           p.rows                                                                AS RowsInPartition,
           CAST(ps.used_page_count / 128.0 AS decimal(10,1))                     AS UsedMB,
           CAST(fg.name AS nvarchar(12))                                         AS FileGroupName
    FROM sys.partitions AS p
    JOIN sys.indexes AS i                  ON i.object_id = p.object_id AND i.index_id = p.index_id
    JOIN sys.partition_schemes AS s        ON s.data_space_id = i.data_space_id
    JOIN sys.partition_functions AS f      ON f.function_id = s.function_id
    JOIN sys.dm_db_partition_stats AS ps   ON ps.partition_id = p.partition_id
    JOIN sys.destination_data_spaces AS dd ON dd.partition_scheme_id = s.data_space_id AND dd.destination_id = p.partition_number
    JOIN sys.filegroups AS fg              ON fg.data_space_id = dd.data_space_id
    LEFT JOIN sys.partition_range_values AS prv
           ON prv.function_id = f.function_id AND prv.boundary_id = p.partition_number - 1
    WHERE i.index_id = 1
      AND f.name = N'pf_TapMonthly'
    ORDER BY TableName, p.partition_number;
END;
GO

-- Add a partition for a future month. Only appends at the right-hand end and only
-- while the last partition is empty, which keeps the split a metadata-only change.
-- Splitting a partition that holds rows moves data under a schema lock and belongs
-- in a maintenance window.
CREATE OR ALTER PROCEDURE fare.usp_AddTapPartition
    @BoundaryDate datetime2(0)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @MaxBoundary datetime2(0);

    SELECT @MaxBoundary = MAX(CAST(prv.value AS datetime2(0)))
    FROM sys.partition_range_values AS prv
    JOIN sys.partition_functions AS f ON f.function_id = prv.function_id
    WHERE f.name = N'pf_TapMonthly';

    IF @BoundaryDate <> DATEFROMPARTS(YEAR(@BoundaryDate), MONTH(@BoundaryDate), 1)
        THROW 50110, 'The boundary must be the first day of a month at midnight.', 1;

    IF @BoundaryDate = @MaxBoundary
    BEGIN
        PRINT 'Boundary already exists. Nothing to do.';
        RETURN 0;
    END;

    IF @BoundaryDate < @MaxBoundary
        THROW 50111, 'Only boundaries later than the current last boundary can be added.', 1;

    IF EXISTS (SELECT 1 FROM fare.Tap AS t WHERE t.TapDateTime >= @MaxBoundary)
       OR EXISTS (SELECT 1 FROM fare.TapArchive AS a WHERE a.TapDateTime >= @MaxBoundary)
        THROW 50112, 'The last partition already holds rows. Splitting it would move data; schedule that as a planned change.', 1;

    ALTER PARTITION SCHEME ps_TapMonthly NEXT USED FG_FARE;
    ALTER PARTITION FUNCTION pf_TapMonthly() SPLIT RANGE (@BoundaryDate);

    RETURN 0;
END;
GO

-- Archive one month by switching its partition into fare.TapArchive.
-- The retention guard keeps the most recent months in the live table.
-- SWITCH requires every index on the target to exist identically on the source,
-- so the two tables are kept with the same set of indexes.
CREATE OR ALTER PROCEDURE fare.usp_ArchiveTapMonth
    @MonthStart    datetime2(0),
    @RetainMonths  int = 6
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Partition   int,
            @Rows        bigint,
            @ArchiveRows bigint,
            @Newest      datetime2(0),
            @NewestMonth datetime2(0);

    IF NOT EXISTS (SELECT 1
                   FROM sys.partition_range_values AS prv
                   JOIN sys.partition_functions AS f ON f.function_id = prv.function_id
                   WHERE f.name = N'pf_TapMonthly'
                     AND CAST(prv.value AS datetime2(0)) = @MonthStart)
        THROW 50120, 'There is no partition starting at that date.', 1;

    SELECT @Newest = MAX(t.TapDateTime) FROM fare.Tap AS t;
    SET @NewestMonth = DATEFROMPARTS(YEAR(@Newest), MONTH(@Newest), 1);

    IF @MonthStart > DATEADD(MONTH, -@RetainMonths, @NewestMonth)
        THROW 50121, 'That month is inside the retention window and must stay in the live table.', 1;

    SET @Partition = $PARTITION.pf_TapMonthly(@MonthStart);

    SELECT @Rows = SUM(p.rows)
    FROM sys.partitions AS p
    WHERE p.object_id = OBJECT_ID(N'fare.Tap') AND p.index_id = 1 AND p.partition_number = @Partition;

    SELECT @ArchiveRows = SUM(p.rows)
    FROM sys.partitions AS p
    WHERE p.object_id = OBJECT_ID(N'fare.TapArchive') AND p.index_id = 1 AND p.partition_number = @Partition;

    IF @Rows = 0
    BEGIN
        PRINT 'No rows in that partition of fare.Tap. Nothing to archive.';
        RETURN 0;
    END;

    -- SWITCH needs an empty target partition.
    IF @ArchiveRows > 0
        THROW 50122, 'The archive already holds rows for that month.', 1;

    BEGIN TRANSACTION;

    ALTER TABLE fare.Tap SWITCH PARTITION @Partition TO fare.TapArchive PARTITION @Partition;

    INSERT dbo.ArchiveLog (TableName, MonthStart, PartitionNumber, RowsMoved)
    VALUES (N'fare.Tap', @MonthStart, @Partition, @Rows);

    COMMIT TRANSACTION;

    RETURN 0;
END;
GO

-- ---------------------------------------------------------------------------
-- Schema version bookkeeping, called by scripts/migrate.sh.
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_RegisterMigration
    @Version       varchar(10),
    @ScriptName    nvarchar(200),
    @ScriptSha256  char(64)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Description nvarchar(200);

    -- 'V002__stop_accessibility.sql' becomes 'stop accessibility'
    SET @Description = REPLACE(REPLACE(SUBSTRING(@ScriptName, CHARINDEX(N'__', @ScriptName) + 2, 200), N'.sql', N''), N'_', N' ');

    INSERT dbo.SchemaVersion (Version, Description, ScriptName, ScriptSha256)
    VALUES (@Version, @Description, @ScriptName, @ScriptSha256);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_UnregisterMigration
    @Version varchar(10)
AS
BEGIN
    SET NOCOUNT ON;

    IF @Version = 'V001'
        THROW 50140, 'The baseline cannot be rolled back.', 1;

    -- Only the most recent migration may be rolled back: later ones may depend on it.
    IF EXISTS (SELECT 1 FROM dbo.SchemaVersion AS v WHERE v.Version > @Version)
        THROW 50141, 'Roll back later migrations first.', 1;

    DELETE FROM dbo.SchemaVersion WHERE Version = @Version;
END;
GO

-- ---------------------------------------------------------------------------
-- Scrub personal data. Called by DBAdmin.dba.usp_RefreshLowerEnvironment right
-- after a production backup is restored as a test copy. Refuses to run in production.
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_ScrubSensitiveData
AS
BEGIN
    SET NOCOUNT ON;

    IF DB_NAME() = N'TransitOps'
        THROW 50130, 'Refusing to scrub the production database.', 1;

    UPDATE ops.Operator
    SET FirstName     = 'Test',
        LastName      = 'Operator' + CAST(OperatorId AS varchar(10)),
        Email         = 'operator' + CAST(OperatorId AS varchar(10)) + '@test.invalid',
        Phone         = '555-0100',
        LicenseNumber = 'TEST' + RIGHT('000000' + CAST(OperatorId AS varchar(10)), 6);
END;
GO

-- ---------------------------------------------------------------------------
-- Workload generator: new taps in November 2026 plus a few updates, so that
-- every log and differential backup in the drill has real changes in it.
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_GenerateWorkload
    @Taps int = 20000
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Base bigint = CAST(IDENT_CURRENT(N'fare.Tap') AS bigint);

    INSERT fare.Tap (TapDateTime, CardId, StopId, FareProductId, Amount, TapType)
    SELECT DATEADD(SECOND, CAST(o.n % 2500000 AS int), CAST('2026-11-01T00:00:00' AS datetime2(0))),
           1 + CAST((o.n * 104729) % 120000 AS int),
           1 + CAST((o.n * 31) % 599 AS int),
           fp.FareProductId,
           fp.Price,
           CASE WHEN fp.FareProductId = 6 THEN 'T' ELSE 'E' END
    FROM dbo.fn_Numbers(@Taps) AS t
    CROSS APPLY (SELECT @Base + t.n AS n) AS o
    JOIN fare.FareProduct AS fp ON fp.FareProductId = CAST(1 + (o.n * 7) % 6 AS smallint);

    UPDATE TOP (500) fare.Card
    SET Balance = Balance + 0.25
    WHERE Status = 'ACTIVE';

    UPDATE TOP (50) maint.WorkOrder
    SET Status = 'IN_PROGRESS'
    WHERE Status = 'OPEN';
END;
GO
