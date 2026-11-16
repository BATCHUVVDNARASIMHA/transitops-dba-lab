/*
    420_pitr_restore.sql

    Point-in-time recovery. Restore the backup chain to a side database
    (TransitOps_PITR), stopping just before the incident:

        FULL (NORECOVERY) -> DIFF (NORECOVERY) -> LOG ... STOPAT -> RECOVERY

    Production is not touched. Restoring over production would also throw away
    every legitimate change made after the incident.
*/
SET NOCOUNT ON;
USE DBAdmin;
GO

DECLARE @StopAt datetime2(3);

SELECT TOP (1) @StopAt = r.KnownGoodTime
FROM dba.DrillRun AS r
WHERE r.Scenario = 'PITR_VEHICLE_STATUS'
ORDER BY r.DrillRunId DESC;

IF @StopAt IS NULL
BEGIN
    RAISERROR(N'No incident recorded. Run 410_incident.sql first.', 16, 1);
    RETURN;
END;

PRINT 'Restoring TransitOps as TransitOps_PITR, stopping at ' + CONVERT(varchar(23), @StopAt, 121);

EXEC dba.usp_RestoreDrill
     @SourceDatabase = N'TransitOps',
     @TargetDatabase = N'TransitOps_PITR',
     @StopAt         = @StopAt,
     @DrillType      = 'PITR',
     @RunCheckDb     = 0,
     @KeepTarget     = 1;
GO
