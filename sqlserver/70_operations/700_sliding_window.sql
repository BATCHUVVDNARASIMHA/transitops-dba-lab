/*
    700_sliding_window.sql

    Data archiving with a sliding partition window on fare.Tap.

      1. add the partition for January 2027 (metadata-only split of the empty last partition)
      2. switch May 2026 out of fare.Tap into fare.TapArchive

    The switch moves a quarter of a million rows by changing metadata. No rows are
    copied, almost nothing is written to the transaction log, and the lock is held
    for milliseconds. Deleting the same rows would log every one of them.
*/
SET NOCOUNT ON;
USE TransitOps;
GO

PRINT '--- Partitions before';
EXEC dbo.usp_PartitionReport;
GO

EXEC fare.usp_AddTapPartition @BoundaryDate = '2027-01-01T00:00:00';
GO

EXEC fare.usp_ArchiveTapMonth @MonthStart = '2026-05-01T00:00:00', @RetainMonths = 5;
GO

PRINT '--- Partitions after';
EXEC dbo.usp_PartitionReport;
GO

SELECT CAST(a.TableName AS nvarchar(12))    AS TableName,
       CONVERT(char(10), a.MonthStart, 120) AS MonthArchived,
       a.PartitionNumber,
       a.RowsMoved,
       CONVERT(char(19), a.ArchivedAt, 120) AS ArchivedAt
FROM dbo.ArchiveLog AS a
ORDER BY a.ArchiveLogId;
GO
