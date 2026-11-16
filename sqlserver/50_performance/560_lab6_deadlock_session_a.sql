/*
    Lab 6, session A: legacy code path "close work order".
    Locks the work order first, then the vehicle.
*/
SET NOCOUNT ON;
USE TransitOps;
GO

DECLARE @WorkOrderId int = 1,
        @VehicleId   int = CAST(DBAdmin.dba.fn_GetConfig(N'Lab6VehicleId') AS int);

BEGIN TRANSACTION;

UPDATE maint.WorkOrder
SET Status = 'CLOSED', ClosedAt = SYSDATETIME()
WHERE WorkOrderId = @WorkOrderId;

WAITFOR DELAY '00:00:04';

UPDATE ops.Vehicle
SET Status = 'ACTIVE', LastModified = SYSDATETIME()
WHERE VehicleId = @VehicleId;

COMMIT TRANSACTION;
GO
