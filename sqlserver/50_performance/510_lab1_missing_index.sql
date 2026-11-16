/*
    Lab 1: missing index

    Symptom   Customer service waits several seconds for a card's tap history.
    Cause     fare.Tap is clustered on (TapDateTime, TapId). Nothing leads on CardId,
              so finding one card's taps reads every row in the date range.
    Fix       A nonclustered index on (CardId, TapDateTime) that covers the query.
              It is created ONLINE and is partition-aligned by default, so monthly
              partition switching keeps working.
    Cost      Every insert into fare.Tap now maintains one more index. Worth it for a
              lookup the business runs all day; not worth it for a monthly report.
*/
SET NOCOUNT ON;
USE TransitOps;
GO

EXEC lab.usp_CardHistory @CardId = 77, @From = '2026-05-01T00:00:00', @To = '2026-11-01T00:00:00';
GO
EXEC DBAdmin.lab.usp_RecordProcStats N'TransitOps', N'lab.usp_CardHistory', 'LAB1_MISSING_INDEX', 'before';
GO

-- What the optimizer itself asked for while running that query.
EXEC DBAdmin.dba.usp_IndexUsageReport @DatabaseName = N'TransitOps';
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes AS i WHERE i.object_id = OBJECT_ID(N'fare.Tap') AND i.name = N'IX_Tap_CardId_TapDateTime')
    CREATE NONCLUSTERED INDEX IX_Tap_CardId_TapDateTime
        ON fare.Tap (CardId, TapDateTime)
        INCLUDE (StopId, Amount)
        WITH (ONLINE = ON);
GO

-- The archive table mirrors the live table's indexes, so that monthly partition
-- switching keeps working after an index is added.
IF NOT EXISTS (SELECT 1 FROM sys.indexes AS i WHERE i.object_id = OBJECT_ID(N'fare.TapArchive') AND i.name = N'IX_Tap_CardId_TapDateTime')
    CREATE NONCLUSTERED INDEX IX_Tap_CardId_TapDateTime
        ON fare.TapArchive (CardId, TapDateTime)
        INCLUDE (StopId, Amount);
GO

EXEC lab.usp_CardHistory @CardId = 77, @From = '2026-05-01T00:00:00', @To = '2026-11-01T00:00:00';
GO
EXEC DBAdmin.lab.usp_RecordProcStats N'TransitOps', N'lab.usp_CardHistory', 'LAB1_MISSING_INDEX', 'after';
GO
