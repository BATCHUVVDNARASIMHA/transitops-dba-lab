/*
    validate.sql

    Post-deployment validation. Run by scripts/migrate.sh against whichever database
    was just changed. Fails loudly if the schema is not what the migrations promise.
*/
SET NOCOUNT ON;
GO

DECLARE @Problems nvarchar(1000) = N'',
        @Db       sysname = DB_NAME();

IF COL_LENGTH(N'ref.Stop', N'IsAccessible') IS NULL
    SET @Problems += N'ref.Stop.IsAccessible is missing. ';
ELSE IF EXISTS (SELECT 1 FROM sys.columns AS c WHERE c.object_id = OBJECT_ID(N'ref.Stop') AND c.name = N'IsAccessible' AND c.is_nullable = 1)
    SET @Problems += N'ref.Stop.IsAccessible is still nullable. ';

IF OBJECT_ID(N'rpt.vw_StopAccessibility', N'V') IS NULL
    SET @Problems += N'rpt.vw_StopAccessibility is missing. ';

IF OBJECT_ID(N'rpt.vw_RouteDelaySummary', N'V') IS NULL
    SET @Problems += N'rpt.vw_RouteDelaySummary is missing. ';

IF NOT EXISTS (SELECT 1 FROM sys.indexes AS i WHERE i.object_id = OBJECT_ID(N'ops.Trip') AND i.name = N'IX_Trip_RouteId_ServiceDate')
    SET @Problems += N'IX_Trip_RouteId_ServiceDate is missing. ';

IF EXISTS (SELECT 1 FROM sys.foreign_keys AS fk WHERE fk.is_not_trusted = 1)
    SET @Problems += N'Untrusted foreign keys exist. ';

IF @Problems <> N''
BEGIN
    RAISERROR(N'Validation failed in %s: %s', 16, 1, @Db, @Problems);
    RETURN;
END;

PRINT 'Validation passed in ' + DB_NAME() + '.';

SELECT v.Version,
       CAST(v.Description AS nvarchar(34)) AS Description,
       CAST(v.AppliedBy AS nvarchar(12))   AS AppliedBy,
       CONVERT(char(19), v.AppliedAt, 120) AS AppliedAt,
       LEFT(v.ScriptSha256, 12)            AS Sha256Prefix
FROM dbo.SchemaVersion AS v
ORDER BY v.Version;
GO
