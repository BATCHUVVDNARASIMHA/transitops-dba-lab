/*
    410_incident.sql

    The incident: someone runs an UPDATE against ops.Vehicle and forgets the WHERE
    clause. Every vehicle in the fleet is now marked RETIRED and dispatch cannot
    assign anything.

    The script records three facts the recovery depends on:
      - a checksum of the correct vehicle statuses, taken before the incident
      - the last moment the data was known to be good (the STOPAT target)
      - a marker row written after the incident, which must NOT appear in the recovered copy
*/
SET NOCOUNT ON;
USE TransitOps;
GO

DECLARE @KnownGood datetime2(3),
        @Incident  datetime2(3);

INSERT dbo.DrillMarker (MarkerName, VehicleStatusChecksum, Note)
SELECT 'PRE_INCIDENT',
       CHECKSUM_AGG(CHECKSUM(v.VehicleId, v.Status)),
       N'Vehicle statuses are correct at this point.'
FROM ops.Vehicle AS v;

-- Leave clear air on both sides of the recovery point.
WAITFOR DELAY '00:00:03';
SET @KnownGood = SYSDATETIME();
WAITFOR DELAY '00:00:03';

-- The bad statement.
UPDATE ops.Vehicle
SET Status = 'RETIRED', LastModified = SYSDATETIME();

SET @Incident = SYSDATETIME();

INSERT dbo.DrillMarker (MarkerName, Note)
VALUES ('POST_INCIDENT', N'Written after the bad update. Must not exist in the recovered copy.');

INSERT DBAdmin.dba.DrillRun (Scenario, KnownGoodTime, IncidentTime, Notes)
VALUES ('PITR_VEHICLE_STATUS', @KnownGood, @Incident, N'UPDATE ops.Vehicle without a WHERE clause.');

PRINT 'Last known good time : ' + CONVERT(varchar(23), @KnownGood, 121);
PRINT 'Incident time        : ' + CONVERT(varchar(23), @Incident, 121);

SELECT v.Status, COUNT(*) AS Vehicles
FROM ops.Vehicle AS v
GROUP BY v.Status;
GO

-- First action in any data-loss incident: back up the log. This captures everything
-- up to now, so the restore can stop anywhere before or after the damage.
WAITFOR DELAY '00:00:02';
EXEC DBAdmin.dba.usp_BackupDatabase @DatabaseName = N'TransitOps', @BackupType = 'LOG', @Description = N'Drill: log backup taken after the incident';
GO
