/*
    R002: roll back V002. Every migration ships with its rollback, and the rollback
    is rehearsed in TEST before the migration is allowed into production.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

BEGIN TRANSACTION;
GO

DROP VIEW IF EXISTS rpt.vw_StopAccessibility;
GO

ALTER TABLE ref.Stop DROP CONSTRAINT IF EXISTS DF_Stop_IsAccessible;
ALTER TABLE ref.Stop DROP COLUMN IF EXISTS IsAccessible;
GO

COMMIT TRANSACTION;
GO
