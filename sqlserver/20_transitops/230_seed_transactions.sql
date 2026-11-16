/*
    230_seed_transactions.sql

    Transactional data for the service period 2026-05-01 to 2026-10-31.

      ops.Trip             202,400 trips (1,100 per day)
      fare.Tap           1,500,000 taps, loaded in six batches
      maint.WorkOrder       30,000 work orders
      maint.WorkOrderTask   90,000 tasks

    Distributions are deliberately skewed, because real transit data is:
      - the hub station (StopId 1) takes about 35 percent of all taps
      - StopId 600 takes exactly 50 taps
      - 2,000 commuter cards account for about a fifth of all taps
    The performance labs depend on that skew.

    The database is in SIMPLE recovery during this load and the taps are loaded in
    batches with a CHECKPOINT between them, which keeps the log small.
*/
SET NOCOUNT ON;
USE TransitOps;
GO

-- ---------------------------------------------------------------------------
-- Trips
-- ---------------------------------------------------------------------------
INSERT ops.Trip (ServiceDate, RouteId, VehicleId, OperatorId, ScheduledStart, ActualStart, ActualEnd, Status)
SELECT c.ServiceDate,
       b.RouteId,
       c.VehicleId,
       c.OperatorId,
       c.ScheduledStart,
       CASE WHEN c.IsCancelled = 1 THEN NULL ELSE DATEADD(MINUTE, c.DelayMinutes, c.ScheduledStart) END,
       CASE WHEN c.IsCancelled = 1 THEN NULL ELSE DATEADD(MINUTE, c.DelayMinutes + c.DurationMinutes, c.ScheduledStart) END,
       CASE WHEN c.IsCancelled = 1 THEN 'CANCELLED' ELSE 'COMPLETED' END
FROM dbo.fn_Numbers(202400) AS t
CROSS APPLY (SELECT CAST((t.n - 1) / 1100 AS int) AS DayOffset,
                    CAST((t.n - 1) % 1100 AS int) AS Slot) AS a
CROSS APPLY (SELECT 1 + (a.Slot % 40) AS RouteId) AS b
CROSS APPLY (SELECT DATEADD(DAY, a.DayOffset, CAST('2026-05-01' AS date)) AS ServiceDate,
                    CASE WHEN b.RouteId <= 4  THEN 1   + CAST((t.n * 7)  % 150 AS int)     -- rail cars
                         WHEN b.RouteId <= 38 THEN 151 + CAST((t.n * 11) % 480 AS int)     -- buses
                         ELSE                      631 + CAST((t.n * 3)  % 20  AS int)     -- streetcars
                    END AS VehicleId,
                    1 + CAST((t.n * 31) % 1200 AS int) AS OperatorId,
                    DATEADD(MINUTE, 300 + ((a.Slot * 67) % 1080),
                            DATEADD(DAY, a.DayOffset, CAST('2026-05-01T00:00:00' AS datetime2(0)))) AS ScheduledStart,
                    CAST((t.n * 13) % 12 AS int) - 2 AS DelayMinutes,
                    35 + CAST(t.n % 40 AS int) AS DurationMinutes,
                    CASE WHEN t.n % 97 = 0 THEN 1 ELSE 0 END AS IsCancelled) AS c;
GO

-- ---------------------------------------------------------------------------
-- Fare taps
-- ---------------------------------------------------------------------------
DECLARE @BatchSize int = 250000,
        @Batches   int = 6,
        @Batch     int = 0;

WHILE @Batch < @Batches
BEGIN
    INSERT fare.Tap (TapDateTime, CardId, StopId, FareProductId, Amount, TapType)
    SELECT DATEADD(SECOND, x.SecondOfDay, DATEADD(DAY, x.DayOffset, CAST('2026-05-01T00:00:00' AS datetime2(0)))),
           x.CardId,
           x.StopId,
           fp.FareProductId,
           fp.Price,
           CASE WHEN fp.FareProductId = 6 THEN 'T'
                WHEN x.StopId <= 38 AND o.n % 2 = 0 THEN 'X'
                ELSE 'E' END
    FROM dbo.fn_Numbers(@BatchSize) AS t
    CROSS APPLY (SELECT t.n + CAST(@Batch AS bigint) * @BatchSize AS n) AS o
    CROSS APPLY (SELECT CAST((o.n * 7907) % 184 AS int) AS DayOffset,                 -- 184 days, May to October
                        18000 + CAST((o.n * 48271) % 68400 AS int) AS SecondOfDay,    -- 05:00 to 24:00
                        CASE WHEN (o.n * 613) % 997 < 200
                             THEN 1 + CAST((o.n * 17) % 2000 AS int)                  -- commuter cards
                             ELSE 1 + CAST((o.n * 104729) % 120000 AS int)            -- everyone else
                        END AS CardId,
                        CASE WHEN o.n % 30000 = 0            THEN 600                 -- the rare stop
                             WHEN (o.n * 7919) % 1009 < 353  THEN 1                   -- the hub station
                             WHEN (o.n * 7919) % 1009 < 605  THEN 2  + CAST((o.n * 31)  % 37  AS int)   -- other stations
                             ELSE                                 39 + CAST((o.n * 131) % 561 AS int)   -- street stops 39 to 599
                        END AS StopId,
                        CAST(1 + (o.n * 7) % 6 AS smallint) AS FareProductId) AS x
    JOIN fare.FareProduct AS fp ON fp.FareProductId = x.FareProductId;

    SET @Batch += 1;
    CHECKPOINT;
END;
GO

-- ---------------------------------------------------------------------------
-- Maintenance work orders and tasks
-- ---------------------------------------------------------------------------
INSERT maint.WorkOrder (VehicleId, GarageId, Category, Priority, Status, OpenedAt, ClosedAt, Summary)
SELECT v.VehicleId,
       v.GarageId,
       x.Category,
       x.Priority,
       x.Status,
       x.OpenedAt,
       CASE WHEN x.Status = 'CLOSED' THEN DATEADD(MINUTE, x.RepairMinutes, x.OpenedAt) END,
       x.Category + ' work on ' + v.FleetNumber
FROM dbo.fn_Numbers(30000) AS t
CROSS APPLY (SELECT 1 + CAST((t.n * 37) % 650 AS int) AS VehicleId,
                    CHOOSE(1 + CAST(t.n % 6 AS int), 'BRAKES', 'HVAC', 'ENGINE', 'DOORS', 'ELECTRICAL', 'INSPECTION') AS Category,
                    CAST(1 + t.n % 4 AS tinyint) AS Priority,
                    CASE WHEN t.n % 10 = 0 THEN 'OPEN' WHEN t.n % 10 = 1 THEN 'IN_PROGRESS' ELSE 'CLOSED' END AS Status,
                    DATEADD(MINUTE, CAST((t.n * 8803) % 264960 AS int), CAST('2026-05-01T00:00:00' AS datetime2(0))) AS OpenedAt,
                    60 + CAST((t.n * 53) % 4000 AS int) AS RepairMinutes) AS x
JOIN ops.Vehicle AS v ON v.VehicleId = x.VehicleId
ORDER BY t.n;      -- identity values follow this order, so WorkOrderId n is always generated from n
GO

INSERT maint.WorkOrderTask (WorkOrderId, TaskCode, LaborHours, PartsCost)
SELECT 1 + CAST(t.n % 30000 AS int),
       'T' + RIGHT('000' + CAST(t.n % 250 AS varchar(10)), 3),
       CAST(0.5 + ((t.n * 7) % 80) / 10.0 AS decimal(5,2)),
       CAST(((t.n * 911) % 150000) / 100.0 AS decimal(9,2))
FROM dbo.fn_Numbers(90000) AS t;
GO

SELECT 'ops.Trip' AS TableName, COUNT_BIG(*) AS RowsLoaded FROM ops.Trip
UNION ALL SELECT 'fare.Tap', COUNT_BIG(*) FROM fare.Tap
UNION ALL SELECT 'maint.WorkOrder', COUNT_BIG(*) FROM maint.WorkOrder
UNION ALL SELECT 'maint.WorkOrderTask', COUNT_BIG(*) FROM maint.WorkOrderTask;
GO
