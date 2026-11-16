/*
    R003: roll back V003.
*/
SET NOCOUNT ON;
GO

DROP VIEW IF EXISTS rpt.vw_RouteDelaySummary;
GO

DROP INDEX IF EXISTS IX_Trip_RouteId_ServiceDate ON ops.Trip;
GO
