/*
    V003: route delay reporting

    Requested by service planning: average departure delay per route and day.
    Adds a supporting index and a reporting view.

    The index is built ONLINE so trips can be written while it is created. Each step
    is guarded, so the script can be rerun safely if it is interrupted.
*/
SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes AS i WHERE i.object_id = OBJECT_ID(N'ops.Trip') AND i.name = N'IX_Trip_RouteId_ServiceDate')
    CREATE NONCLUSTERED INDEX IX_Trip_RouteId_ServiceDate
        ON ops.Trip (RouteId, ServiceDate)
        INCLUDE (ScheduledStart, ActualStart, Status)
        WITH (ONLINE = ON);
GO

CREATE OR ALTER VIEW rpt.vw_RouteDelaySummary
AS
SELECT tr.ServiceDate,
       r.RouteCode,
       COUNT(*)                                                                         AS CompletedTrips,
       CAST(AVG(1.0 * DATEDIFF(MINUTE, tr.ScheduledStart, tr.ActualStart)) AS decimal(6,2)) AS AvgDepartureDelayMinutes,
       MAX(DATEDIFF(MINUTE, tr.ScheduledStart, tr.ActualStart))                          AS MaxDepartureDelayMinutes
FROM ops.Trip AS tr
JOIN ref.Route AS r ON r.RouteId = tr.RouteId
WHERE tr.Status = 'COMPLETED'
GROUP BY tr.ServiceDate, r.RouteCode;
GO
