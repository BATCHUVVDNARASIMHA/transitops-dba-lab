/*
    250_post_load.sql

    Finish the build: switch to FULL recovery, turn on Query Store, record the
    baseline schema version.

    FULL recovery only takes effect for recovery purposes once a full backup exists.
    Until then the log is truncated on checkpoint as if the database were in SIMPLE
    recovery. The first step of the backup drill takes that full backup.
*/
SET NOCOUNT ON;
USE master;
GO

ALTER DATABASE TransitOps SET RECOVERY FULL;
GO

ALTER DATABASE TransitOps SET QUERY_STORE = ON
    (OPERATION_MODE = READ_WRITE,
     QUERY_CAPTURE_MODE = AUTO,
     MAX_STORAGE_SIZE_MB = 256,
     INTERVAL_LENGTH_MINUTES = 15,
     DATA_FLUSH_INTERVAL_SECONDS = 60,
     CLEANUP_POLICY = (STALE_QUERY_THRESHOLD_DAYS = 30));
GO

USE TransitOps;
GO

INSERT dbo.SchemaVersion (Version, Description, ScriptName)
VALUES ('V001', N'Baseline schema and seed data', N'sqlserver/20_transitops');
GO

EXEC dbo.usp_PartitionReport;
GO

SELECT CAST(d.name AS nvarchar(20))                 AS DatabaseName,
       CAST(d.recovery_model_desc AS nvarchar(12))  AS RecoveryModel,
       CAST(d.page_verify_option_desc AS nvarchar(12)) AS PageVerify,
       d.compatibility_level                        AS CompatibilityLevel,
       d.is_query_store_on                          AS QueryStoreOn,
       CAST(d.collation_name AS nvarchar(32))       AS Collation
FROM sys.databases AS d
WHERE d.name = N'TransitOps';
GO
