/*
    430_pitr_repair.sql

    Prove the recovered copy is from the right moment, then repair production
    surgically: copy only the damaged column back from TransitOps_PITR.

    Proof of the recovery point:
      - the PRE_INCIDENT marker exists in the copy  (not restored too early)
      - the POST_INCIDENT marker does not           (not restored too late)

    The repair runs in a transaction and commits only if the vehicle statuses match
    the checksum recorded before the incident.
*/
SET NOCOUNT ON;
USE TransitOps;
GO

DECLARE @PreId    int,
        @PostId   int,
        @Expected int,
        @Actual   int,
        @Repaired int;

SELECT @PreId  = MAX(m.DrillMarkerId) FROM dbo.DrillMarker AS m WHERE m.MarkerName = 'PRE_INCIDENT';
SELECT @PostId = MAX(m.DrillMarkerId) FROM dbo.DrillMarker AS m WHERE m.MarkerName = 'POST_INCIDENT';

IF NOT EXISTS (SELECT 1 FROM TransitOps_PITR.dbo.DrillMarker AS m WHERE m.DrillMarkerId = @PreId)
    THROW 50200, 'The recovered copy is missing the PRE_INCIDENT marker: it was restored to a point that is too early.', 1;

IF EXISTS (SELECT 1 FROM TransitOps_PITR.dbo.DrillMarker AS m WHERE m.DrillMarkerId = @PostId)
    THROW 50201, 'The recovered copy contains the POST_INCIDENT marker: it was restored past the incident.', 1;

SELECT @Expected = m.VehicleStatusChecksum
FROM dbo.DrillMarker AS m
WHERE m.DrillMarkerId = @PreId;

BEGIN TRANSACTION;

UPDATE v
SET v.Status       = r.Status,
    v.LastModified = SYSDATETIME()
FROM ops.Vehicle AS v
JOIN TransitOps_PITR.ops.Vehicle AS r ON r.VehicleId = v.VehicleId
WHERE v.Status <> r.Status;

SET @Repaired = @@ROWCOUNT;

SELECT @Actual = CHECKSUM_AGG(CHECKSUM(v.VehicleId, v.Status))
FROM ops.Vehicle AS v;

IF @Actual <> @Expected
BEGIN
    ROLLBACK TRANSACTION;
    THROW 50202, 'Repair validation failed: vehicle statuses do not match the pre-incident checksum. Nothing was changed.', 1;
END;

COMMIT TRANSACTION;

UPDATE d
SET d.ValidationStatus = 'PASSED',
    d.Notes = ISNULL(d.Notes, N'') + N'Recovery point verified by markers. '
            + CAST(@Repaired AS nvarchar(10)) + N' vehicle rows repaired from the copy and verified against the pre-incident checksum. '
FROM DBAdmin.dba.RestoreDrillLog AS d
WHERE d.DrillId = (SELECT MAX(x.DrillId) FROM DBAdmin.dba.RestoreDrillLog AS x WHERE x.DrillType = 'PITR');

PRINT CAST(@Repaired AS varchar(10)) + ' vehicle rows repaired.';

SELECT v.Status, COUNT(*) AS Vehicles
FROM ops.Vehicle AS v
GROUP BY v.Status;
GO

-- The side database has done its job.
USE master;
GO
ALTER DATABASE TransitOps_PITR SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE TransitOps_PITR;
GO

-- Protect the repair itself.
EXEC DBAdmin.dba.usp_BackupDatabase @DatabaseName = N'TransitOps', @BackupType = 'LOG', @Description = N'Drill: log backup after the repair';
GO
