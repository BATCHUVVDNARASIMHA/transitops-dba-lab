/*
    Lab 3: a function wrapped around an indexed column

    Symptom   A report on one station for one day reads the whole table.
    Cause     The predicate is CONVERT(char(8), TapDateTime, 112) = '20260815'.
              The engine must compute the function for every row before it can
              compare, so it can neither seek on the clustered key nor skip partitions.
    Fix       Rewrite as a half-open range on the bare column:
                  TapDateTime >= @Day AND TapDateTime < DATEADD(DAY, 1, @Day)
              No index change. The query now touches one day of one partition.
*/
SET NOCOUNT ON;
USE TransitOps;
GO

EXEC lab.usp_StopDayTaps_FunctionOnColumn @StopId = 1, @Day = '2026-08-15';
GO
EXEC DBAdmin.lab.usp_RecordProcStats N'TransitOps', N'lab.usp_StopDayTaps_FunctionOnColumn', 'LAB3_SARGABILITY', 'before';
GO

EXEC lab.usp_StopDayTaps @StopId = 1, @Day = '2026-08-15';
GO
EXEC DBAdmin.lab.usp_RecordProcStats N'TransitOps', N'lab.usp_StopDayTaps', 'LAB3_SARGABILITY', 'after';
GO
