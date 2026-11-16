/*
    990_summary.sql
    Print every assertion and fail the run if any of them failed.
*/
SET NOCOUNT ON;
USE DBAdmin;
GO

SELECT CAST(t.Suite AS varchar(13))                              AS Suite,
       CASE t.Passed WHEN 1 THEN 'PASS' ELSE 'FAIL' END          AS Result,
       CAST(t.TestName AS nvarchar(88))                          AS Test,
       CAST(ISNULL(t.Detail, N'') AS nvarchar(90))               AS Detail
FROM dba.TestResult AS t
ORDER BY t.TestResultId;
GO

DECLARE @Total int, @Failed int;

SELECT @Total = COUNT(*), @Failed = ISNULL(SUM(CASE WHEN t.Passed = 0 THEN 1 ELSE 0 END), 0)
FROM dba.TestResult AS t;

IF @Total = 0
    RAISERROR(N'No test results were recorded.', 16, 1);
ELSE IF @Failed > 0
    RAISERROR(N'%d of %d tests FAILED.', 16, 1, @Failed, @Total);
ELSE
    PRINT 'All ' + CAST(@Total AS varchar(10)) + ' tests passed.';
GO
