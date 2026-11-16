/*
    500_lab_objects.sql

    Objects used by the performance labs.

    Measurement method: each lab query lives in a stored procedure. After it runs,
    sys.dm_exec_procedure_stats holds the logical reads, CPU time and elapsed time of
    that execution. lab.usp_RecordProcStats copies those numbers into lab.PerfResult,
    so "before" and "after" are measured by the engine, not estimated.
    Logical reads are the headline metric: unlike elapsed time they do not depend on
    how busy the host is.
*/
SET NOCOUNT ON;
USE DBAdmin;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE lab.usp_RecordProcStats
    @DatabaseName sysname,
    @ProcName     nvarchar(300),     -- schema-qualified
    @Lab          varchar(40),
    @Phase        varchar(20)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ObjectId  int = OBJECT_ID(QUOTENAME(@DatabaseName) + N'.' + @ProcName),
            @Reads     bigint,
            @CpuUs     bigint,
            @ElapsedUs bigint;

    IF @ObjectId IS NULL
    BEGIN
        RAISERROR(N'Procedure %s not found in %s.', 16, 1, @ProcName, @DatabaseName);
        RETURN 1;
    END;

    SELECT TOP (1)
           @Reads     = ps.last_logical_reads,
           @CpuUs     = ps.last_worker_time,
           @ElapsedUs = ps.last_elapsed_time
    FROM sys.dm_exec_procedure_stats AS ps
    WHERE ps.database_id = DB_ID(@DatabaseName)
      AND ps.object_id = @ObjectId
    ORDER BY ps.last_execution_time DESC;

    IF @Reads IS NULL
    BEGIN
        RAISERROR(N'No cached execution statistics for %s. Execute it first.', 16, 1, @ProcName);
        RETURN 1;
    END;

    INSERT lab.PerfResult (Lab, Phase, Metric, Value, Detail)
    VALUES (@Lab, @Phase, 'logical_reads', @Reads,              @ProcName),
           (@Lab, @Phase, 'cpu_ms',        @CpuUs / 1000.0,     @ProcName),
           (@Lab, @Phase, 'elapsed_ms',    @ElapsedUs / 1000.0, @ProcName);

    RETURN 0;
END;
GO

-- Latest before and after value per lab and metric.
CREATE OR ALTER VIEW lab.vw_PerfSummary
AS
WITH Latest AS (
    SELECT r.Lab, r.Phase, r.Metric, r.Value,
           ROW_NUMBER() OVER (PARTITION BY r.Lab, r.Phase, r.Metric ORDER BY r.PerfResultId DESC) AS rn
    FROM lab.PerfResult AS r
)
SELECT b.Lab,
       b.Metric,
       b.Value AS BeforeValue,
       a.Value AS AfterValue,
       CAST(CASE WHEN a.Value > 0 THEN b.Value / a.Value END AS decimal(18,1)) AS ImprovementFactor
FROM Latest AS b
JOIN Latest AS a
  ON a.Lab = b.Lab AND a.Metric = b.Metric AND a.Phase = 'after' AND a.rn = 1
WHERE b.Phase = 'before'
  AND b.rn = 1;
GO

USE TransitOps;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- Lab 1: a rider disputes a charge; customer service pulls the card's history.
CREATE OR ALTER PROCEDURE lab.usp_CardHistory
    @CardId int,
    @From   datetime2(0),
    @To     datetime2(0)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT COUNT(*)                 AS Taps,
           SUM(t.Amount)            AS TotalFare,
           MIN(t.TapDateTime)       AS FirstTap,
           MAX(t.TapDateTime)       AS LastTap,
           COUNT(DISTINCT t.StopId) AS DistinctStops
    FROM fare.Tap AS t
    WHERE t.CardId = @CardId
      AND t.TapDateTime >= @From
      AND t.TapDateTime <  @To;
END;
GO

-- Lab 2: card lookup by serial. The application driver sends strings as Unicode.
CREATE OR ALTER PROCEDURE lab.usp_FindCard_UnicodeParam
    @CardSerial nvarchar(20)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT c.CardId, c.Status, c.Balance
    FROM fare.Card AS c
    WHERE c.CardSerial = @CardSerial;
END;
GO

CREATE OR ALTER PROCEDURE lab.usp_FindCard
    @CardSerial varchar(20)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT c.CardId, c.Status, c.Balance
    FROM fare.Card AS c
    WHERE c.CardSerial = @CardSerial;
END;
GO

-- Lab 3: taps at one stop on one day, written with a function around the column.
CREATE OR ALTER PROCEDURE lab.usp_StopDayTaps_FunctionOnColumn
    @StopId int,
    @Day    date
AS
BEGIN
    SET NOCOUNT ON;

    SELECT COUNT(*) AS Taps, SUM(t.Amount) AS Revenue
    FROM fare.Tap AS t
    WHERE t.StopId = @StopId
      AND CONVERT(char(8), t.TapDateTime, 112) = CONVERT(char(8), @Day, 112);
END;
GO

CREATE OR ALTER PROCEDURE lab.usp_StopDayTaps
    @StopId int,
    @Day    date
AS
BEGIN
    SET NOCOUNT ON;

    -- Same result, but the column is left bare so the predicate can seek on the
    -- clustered key and eliminate every partition except one.
    SELECT COUNT(*) AS Taps, SUM(t.Amount) AS Revenue
    FROM fare.Tap AS t
    WHERE t.StopId = @StopId
      AND t.TapDateTime >= @Day
      AND t.TapDateTime <  DATEADD(DAY, 1, @Day);
END;
GO

-- Lab 4: revenue for one stop. The right plan depends on which stop is asked for.
CREATE OR ALTER PROCEDURE lab.usp_StopRevenue
    @StopId int
AS
BEGIN
    SET NOCOUNT ON;

    SELECT COUNT(*) AS Taps, SUM(t.Amount) AS Revenue
    FROM fare.Tap AS t
    WHERE t.StopId = @StopId;
END;
GO

CREATE OR ALTER PROCEDURE lab.usp_StopRevenue_Recompile
    @StopId int
AS
BEGIN
    SET NOCOUNT ON;

    SELECT COUNT(*) AS Taps, SUM(t.Amount) AS Revenue
    FROM fare.Tap AS t
    WHERE t.StopId = @StopId
    OPTION (RECOMPILE);
END;
GO
