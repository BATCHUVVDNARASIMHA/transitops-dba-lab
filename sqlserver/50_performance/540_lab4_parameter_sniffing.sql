/*
    Lab 4: parameter sniffing

    Symptom   The same procedure is instant on some days and painfully slow on others.
    Cause     The plan is compiled for the first parameter value it sees and reused
              for every later call. StopId 600 has 50 taps; StopId 1 (the hub) has
              about half a million. A plan built for stop 600 seeks the StopId index
              and looks each row up in the clustered index: perfect for 50 rows,
              terrible for half a million.
    Fix A     OPTION (RECOMPILE) on the statement: a fresh plan per call. Costs a
              compile each time, which is fine for a query that runs a few times a minute.
    Fix B     SQL Server 2022 Parameter Sensitive Plan optimization keeps several
              plans for one statement and picks by parameter value. It is on by
              default at compatibility level 160. The lab turns it off to reproduce
              the classic problem, then turns it back on and measures again.
    Not used  Forcing one plan (Query Store, OPTIMIZE FOR): that only chooses which
              group of callers gets the bad plan.
*/
SET NOCOUNT ON;
USE TransitOps;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes AS i WHERE i.object_id = OBJECT_ID(N'fare.Tap') AND i.name = N'IX_Tap_StopId')
    CREATE NONCLUSTERED INDEX IX_Tap_StopId
        ON fare.Tap (StopId)
        WITH (ONLINE = ON);
GO

-- Mirror the index on the archive table (see lab 1).
IF NOT EXISTS (SELECT 1 FROM sys.indexes AS i WHERE i.object_id = OBJECT_ID(N'fare.TapArchive') AND i.name = N'IX_Tap_StopId')
    CREATE NONCLUSTERED INDEX IX_Tap_StopId
        ON fare.TapArchive (StopId);
GO

-- Reproduce the pre-2022 behaviour.
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 16
    EXEC (N'ALTER DATABASE SCOPED CONFIGURATION SET PARAMETER_SENSITIVE_PLAN_OPTIMIZATION = OFF;');
GO

EXEC sys.sp_recompile N'lab.usp_StopRevenue';
GO
EXEC lab.usp_StopRevenue @StopId = 600;     -- first call: the plan is compiled for the rare stop
GO
EXEC lab.usp_StopRevenue @StopId = 1;       -- second call: the hub reuses that plan
GO
EXEC DBAdmin.lab.usp_RecordProcStats N'TransitOps', N'lab.usp_StopRevenue', 'LAB4_PARAMETER_SNIFFING', 'before';
GO

-- Fix A
EXEC lab.usp_StopRevenue_Recompile @StopId = 1;
GO
EXEC DBAdmin.lab.usp_RecordProcStats N'TransitOps', N'lab.usp_StopRevenue_Recompile', 'LAB4_PARAMETER_SNIFFING', 'after';
GO

-- Fix B: same procedure, same call order, Parameter Sensitive Plan optimization back on.
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 16
    EXEC (N'ALTER DATABASE SCOPED CONFIGURATION SET PARAMETER_SENSITIVE_PLAN_OPTIMIZATION = ON;');
GO
EXEC sys.sp_recompile N'lab.usp_StopRevenue';
GO
EXEC lab.usp_StopRevenue @StopId = 600;
GO
EXEC lab.usp_StopRevenue @StopId = 1;
GO
EXEC DBAdmin.lab.usp_RecordProcStats N'TransitOps', N'lab.usp_StopRevenue', 'LAB4_PARAMETER_SNIFFING', 'after_psp';
GO
