/*
    Lab 5, session A: a maintenance batch that keeps its transaction open far too
    long. It updates every vehicle of one garage and then sits on the locks.
*/
SET NOCOUNT ON;
USE TransitOps;
GO

BEGIN TRANSACTION;

UPDATE ops.Vehicle
SET LastModified = SYSDATETIME()
WHERE GarageId = 1;

WAITFOR DELAY '00:00:12';

COMMIT TRANSACTION;
GO
