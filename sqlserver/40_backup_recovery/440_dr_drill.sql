/*
    440_dr_drill.sql

    Disaster recovery drill: restore the whole chain to a side database, check it
    for corruption, compare row counts with production, and log the measured
    recovery time against the RTO in dba.BackupPolicy. The side database is dropped
    afterwards. The "DBA - Restore Drill" Agent job runs the same procedure weekly.
*/
SET NOCOUNT ON;
USE DBAdmin;
GO

EXEC dba.usp_BackupDatabase @DatabaseName = N'TransitOps', @BackupType = 'LOG', @Description = N'Drill: latest log before the DR drill';
GO

EXEC dba.usp_RestoreDrill
     @SourceDatabase = N'TransitOps',
     @TargetDatabase = N'TransitOps_DRDrill',
     @DrillType      = 'FULL_CHAIN',
     @RunCheckDb     = 1,
     @KeepTarget     = 0;
GO
