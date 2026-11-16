/*
    310_data_protection.sql

    Two controls on top of ordinary permissions:

    1. Dynamic data masking on operator contact and licence details. Anyone with
       SELECT but without UNMASK sees masked values. Masking is a convenience layer
       for honest users, not a security boundary: it does not stop inference through
       WHERE clauses. That is why the reporting role is also denied the table outright.

    2. Row-level security on maintenance work orders. A garage supervisor sees and
       updates only the work orders of the garages mapped to them in sec.UserGarage.
       The filter is enforced by the engine on every query, including ad hoc ones,
       so it cannot be forgotten in application code.
*/
SET NOCOUNT ON;
USE TransitOps;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ---------------------------------------------------------------------------
-- Dynamic data masking
-- ---------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.masked_columns AS mc WHERE mc.object_id = OBJECT_ID(N'ops.Operator') AND mc.name = N'Email')
    ALTER TABLE ops.Operator ALTER COLUMN Email ADD MASKED WITH (FUNCTION = 'email()');

IF NOT EXISTS (SELECT 1 FROM sys.masked_columns AS mc WHERE mc.object_id = OBJECT_ID(N'ops.Operator') AND mc.name = N'Phone')
    ALTER TABLE ops.Operator ALTER COLUMN Phone ADD MASKED WITH (FUNCTION = 'partial(0,"XXX-",4)');

IF NOT EXISTS (SELECT 1 FROM sys.masked_columns AS mc WHERE mc.object_id = OBJECT_ID(N'ops.Operator') AND mc.name = N'LicenseNumber')
    ALTER TABLE ops.Operator ALTER COLUMN LicenseNumber ADD MASKED WITH (FUNCTION = 'partial(3,"XXXXXX",3)');
GO

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------
DROP SECURITY POLICY IF EXISTS sec.WorkOrderGaragePolicy;
GO

IF OBJECT_ID(N'sec.UserGarage', N'U') IS NULL
    CREATE TABLE sec.UserGarage (
        UserName  sysname  NOT NULL,
        GarageId  int      NOT NULL CONSTRAINT FK_UserGarage_Garage REFERENCES ref.Garage (GarageId),
        CONSTRAINT PK_UserGarage PRIMARY KEY CLUSTERED (UserName, GarageId)
    );
GO

IF NOT EXISTS (SELECT 1 FROM sec.UserGarage AS ug WHERE ug.UserName = N'maint_supervisor_north')
    INSERT sec.UserGarage (UserName, GarageId)
    VALUES (N'maint_supervisor_north', 1);
GO

-- Predicate: a row is visible when the caller owns the database, belongs to the
-- all-garages role, or is mapped to the row's garage.
CREATE OR ALTER FUNCTION sec.fn_WorkOrderAccess (@GarageId int)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT 1 AS AccessGranted
    WHERE IS_MEMBER(N'db_owner') = 1
       OR IS_MEMBER(N'role_workorder_all_garages') = 1
       OR EXISTS (SELECT 1
                  FROM sec.UserGarage AS ug
                  WHERE ug.UserName = USER_NAME()
                    AND ug.GarageId = @GarageId);
GO

-- FILTER hides other garages' rows from SELECT, UPDATE and DELETE.
-- BLOCK AFTER UPDATE stops a supervisor from reassigning a work order to a garage
-- they cannot see.
CREATE SECURITY POLICY sec.WorkOrderGaragePolicy
    ADD FILTER PREDICATE sec.fn_WorkOrderAccess (GarageId) ON maint.WorkOrder,
    ADD BLOCK PREDICATE  sec.fn_WorkOrderAccess (GarageId) ON maint.WorkOrder AFTER UPDATE
    WITH (STATE = ON, SCHEMABINDING = ON);
GO

SELECT CAST(OBJECT_SCHEMA_NAME(mc.object_id) + N'.' + OBJECT_NAME(mc.object_id) AS nvarchar(20)) AS TableName,
       CAST(mc.name AS nvarchar(20))             AS ColumnName,
       CAST(mc.masking_function AS nvarchar(40)) AS MaskingFunction
FROM sys.masked_columns AS mc
ORDER BY TableName, ColumnName;

SELECT CAST(sp.name AS nvarchar(30)) AS SecurityPolicy,
       sp.is_enabled                 AS IsEnabled,
       CAST(pr.predicate_type_desc AS nvarchar(10)) AS PredicateType,
       CAST(OBJECT_SCHEMA_NAME(pr.target_object_id) + N'.' + OBJECT_NAME(pr.target_object_id) AS nvarchar(20)) AS TargetTable
FROM sys.security_policies AS sp
JOIN sys.security_predicates AS pr ON pr.object_id = sp.object_id
ORDER BY PredicateType;
GO
