/*
    400_backup_chain.sql

    Build a realistic backup chain for TransitOps with application activity between
    the backups:

        FULL -> workload -> LOG -> workload -> DIFF -> workload -> LOG

    then full backups of the system and toolkit databases. Every backup is taken
    WITH CHECKSUM and verified with RESTORE VERIFYONLY by dba.usp_BackupDatabase.
*/
SET NOCOUNT ON;
USE DBAdmin;
GO

PRINT '';
PRINT '--- FULL backup. In FULL recovery this is what starts the log chain.';
EXEC dba.usp_BackupDatabase @DatabaseName = N'TransitOps', @BackupType = 'FULL', @Description = N'Drill: base full backup';
GO

EXEC TransitOps.dbo.usp_GenerateWorkload @Taps = 20000;
GO

PRINT '';
PRINT '--- LOG backup 1';
EXEC dba.usp_BackupDatabase @DatabaseName = N'TransitOps', @BackupType = 'LOG', @Description = N'Drill: log backup 1';
GO

EXEC TransitOps.dbo.usp_GenerateWorkload @Taps = 20000;
GO

PRINT '';
PRINT '--- DIFFERENTIAL backup. Everything changed since the full backup.';
EXEC dba.usp_BackupDatabase @DatabaseName = N'TransitOps', @BackupType = 'DIFF', @Description = N'Drill: differential backup';
GO

EXEC TransitOps.dbo.usp_GenerateWorkload @Taps = 20000;
GO

PRINT '';
PRINT '--- LOG backup 2';
EXEC dba.usp_BackupDatabase @DatabaseName = N'TransitOps', @BackupType = 'LOG', @Description = N'Drill: log backup 2';
GO

PRINT '';
PRINT '--- System and toolkit databases';
EXEC dba.usp_BackupDatabase @DatabaseName = N'master',  @BackupType = 'FULL', @Description = N'Drill: system database';
GO
EXEC dba.usp_BackupDatabase @DatabaseName = N'msdb',    @BackupType = 'FULL', @Description = N'Drill: system database';
GO
EXEC dba.usp_BackupDatabase @DatabaseName = N'model',   @BackupType = 'FULL', @Description = N'Drill: system database';
GO
EXEC dba.usp_BackupDatabase @DatabaseName = N'DBAdmin', @BackupType = 'FULL', @Description = N'Drill: DBA toolkit';
GO

SELECT CAST(l.DatabaseName AS nvarchar(12))       AS DatabaseName,
       l.BackupType,
       CONVERT(char(19), l.StartedAt, 120)        AS StartedAt,
       DATEDIFF(MILLISECOND, l.StartedAt, l.FinishedAt) AS DurationMs,
       l.SizeMB,
       l.CompressedSizeMB,
       l.Verified,
       l.Status
FROM dba.BackupLog AS l
ORDER BY l.BackupLogId;
GO
