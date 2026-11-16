/*
    Lab 6, session B: legacy code path "pull vehicle from service".
    Locks the vehicle first, then the work order: the opposite order to session A.
    Each session ends up waiting for a lock the other holds. SQL Server detects the
    cycle, rolls one of them back with error 1205 and lets the other finish.
*/
SET NOCOUNT ON;
USE TransitOps;
GO

DECLARE @WorkOrderId int = 1,
        @VehicleId   int = CAST(DBAdmin.dba.fn_GetConfig(N'Lab6VehicleId') AS int);

BEGIN TRANSACTION;

UPDATE ops.Vehicle
SET Status = 'IN_SHOP', LastModified = SYSDATETIME()
WHERE VehicleId = @VehicleId;

WAITFOR DELAY '00:00:04';

UPDATE maint.WorkOrder
SET Status = 'IN_PROGRESS', Priority = 1, ClosedAt = NULL
WHERE WorkOrderId = @WorkOrderId;

COMMIT TRANSACTION;
GO
