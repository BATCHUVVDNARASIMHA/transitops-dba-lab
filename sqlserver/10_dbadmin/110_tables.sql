/*
    110_tables.sql

    DBAdmin tables: configuration, backup policy, and the run logs every procedure
    writes to. The logs are the audit trail a DBA shows when asked "when did we last
    prove we can restore this database?".
*/
SET NOCOUNT ON;
USE DBAdmin;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------
IF OBJECT_ID(N'dba.Config', N'U') IS NULL
    CREATE TABLE dba.Config (
        Name        sysname        NOT NULL CONSTRAINT PK_Config PRIMARY KEY,
        Value       nvarchar(400)  NOT NULL,
        Description nvarchar(400)  NULL,
        ModifiedAt  datetime2(0)   NOT NULL CONSTRAINT DF_Config_ModifiedAt DEFAULT (SYSDATETIME())
    );
GO

CREATE OR ALTER FUNCTION dba.fn_GetConfig (@Name sysname)
RETURNS nvarchar(400)
AS
BEGIN
    RETURN (SELECT c.Value FROM dba.Config AS c WHERE c.Name = @Name);
END;
GO

CREATE OR ALTER PROCEDURE dba.usp_SetConfig
    @Name        sysname,
    @Value       nvarchar(400),
    @Description nvarchar(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dba.Config
    SET Value       = @Value,
        Description = COALESCE(@Description, Description),
        ModifiedAt  = SYSDATETIME()
    WHERE Name = @Name;

    IF @@ROWCOUNT = 0
        INSERT dba.Config (Name, Value, Description)
        VALUES (@Name, @Value, @Description);
END;
GO

-- Defaults derived from the instance. The deployment script overrides the paths for the container.
DECLARE @BackupRoot nvarchar(400) = COALESCE(CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS nvarchar(400)), N'/var/opt/mssql/data'),
        @ErrorLog   nvarchar(400) = CAST(SERVERPROPERTY('ErrorLogFileName') AS nvarchar(400)),
        @AuditPath  nvarchar(400);

-- Directory of the error log: everything before the last slash or backslash.
SET @AuditPath = LEFT(@ErrorLog, LEN(@ErrorLog) - PATINDEX(N'%[/\]%', REVERSE(@ErrorLog)));

IF dba.fn_GetConfig(N'BackupRoot') IS NULL
    EXEC dba.usp_SetConfig N'BackupRoot', @BackupRoot, N'Root folder for backup files. One subfolder per database and backup type.';
IF dba.fn_GetConfig(N'AuditPath') IS NULL
    EXEC dba.usp_SetConfig N'AuditPath', @AuditPath, N'Folder for SQL Server Audit files.';
IF dba.fn_GetConfig(N'AgentJobsEnabled') IS NULL
    EXEC dba.usp_SetConfig N'AgentJobsEnabled', N'0', N'1 = create Agent jobs enabled. The lab keeps them disabled so an idle container does not fill its volume.';
GO

-- ---------------------------------------------------------------------------
-- Backup policy: one row per database. This is the contract with the business.
-- ---------------------------------------------------------------------------
IF OBJECT_ID(N'dba.BackupPolicy', N'U') IS NULL
    CREATE TABLE dba.BackupPolicy (
        DatabaseName     sysname        NOT NULL CONSTRAINT PK_BackupPolicy PRIMARY KEY,
        Tier             varchar(10)    NOT NULL,
        RecoveryModel    varchar(12)    NOT NULL CONSTRAINT CK_BackupPolicy_RecoveryModel CHECK (RecoveryModel IN ('FULL', 'SIMPLE', 'BULK_LOGGED')),
        FullEveryHours   int            NULL,     -- NULL = exempt (for example a test copy refreshed from production)
        DiffEveryHours   int            NULL,
        LogEveryMinutes  int            NULL,
        RetentionDays    int            NOT NULL,
        RpoMinutes       int            NOT NULL, -- maximum tolerable data loss
        RtoMinutes       int            NOT NULL, -- maximum tolerable time to restore
        Notes            nvarchar(400)  NULL
    );
GO

IF NOT EXISTS (SELECT 1 FROM dba.BackupPolicy)
    INSERT dba.BackupPolicy (DatabaseName, Tier, RecoveryModel, FullEveryHours, DiffEveryHours, LogEveryMinutes, RetentionDays, RpoMinutes, RtoMinutes, Notes)
    VALUES
        (N'TransitOps',      'TIER1',   'FULL',   24,   6,    15,   14, 15,   60,  N'Fare collection and fleet operations. Point-in-time recovery required.'),
        (N'TransitOps_TEST', 'NONPROD', 'SIMPLE', NULL, NULL, NULL, 0,  1440, 240, N'Refreshed from production backups with PII scrubbed. Not backed up.'),
        (N'DBAdmin',         'TIER2',   'SIMPLE', 24,   NULL, NULL, 7,  1440, 240, N'DBA toolkit and run history.'),
        (N'master',          'SYSTEM',  'SIMPLE', 24,   NULL, NULL, 7,  1440, 240, N'Logins, server configuration.'),
        (N'msdb',            'SYSTEM',  'SIMPLE', 24,   NULL, NULL, 7,  1440, 240, N'Agent jobs and backup history.'),
        (N'model',           'SYSTEM',  'FULL',   168,  NULL, NULL, 7,  10080, 240, N'Template database. Weekly full backup is enough.');
GO

-- model keeps whatever recovery model the installer gave it. Record the actual value
-- so drift detection starts from the truth instead of an assumption.
UPDATE p
SET p.RecoveryModel = CAST(d.recovery_model_desc AS varchar(12)) COLLATE DATABASE_DEFAULT
FROM dba.BackupPolicy AS p
JOIN sys.databases AS d ON d.name = p.DatabaseName COLLATE DATABASE_DEFAULT
WHERE p.DatabaseName = N'model';
GO

-- ---------------------------------------------------------------------------
-- Run logs
-- ---------------------------------------------------------------------------
IF OBJECT_ID(N'dba.BackupLog', N'U') IS NULL
    CREATE TABLE dba.BackupLog (
        BackupLogId       bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_BackupLog PRIMARY KEY,
        DatabaseName      sysname         NOT NULL,
        BackupType        varchar(4)      NOT NULL,
        IsCopyOnly        bit             NOT NULL CONSTRAINT DF_BackupLog_IsCopyOnly DEFAULT (0),
        FilePath          nvarchar(520)   NOT NULL,
        StartedAt         datetime2(3)    NOT NULL,
        FinishedAt        datetime2(3)    NULL,
        SizeMB            decimal(12,2)   NULL,
        CompressedSizeMB  decimal(12,2)   NULL,
        Verified          bit             NOT NULL CONSTRAINT DF_BackupLog_Verified DEFAULT (0),
        Status            varchar(10)     NOT NULL,
        ErrorMessage      nvarchar(2048)  NULL,
        Description       nvarchar(200)   NULL
    );
GO

IF OBJECT_ID(N'dba.RestoreDrillLog', N'U') IS NULL
    CREATE TABLE dba.RestoreDrillLog (
        DrillId              int IDENTITY(1,1) NOT NULL CONSTRAINT PK_RestoreDrillLog PRIMARY KEY,
        DrillType            varchar(20)     NOT NULL,   -- FULL_CHAIN | PITR | TEST_REFRESH
        SourceDatabase       sysname         NOT NULL,
        TargetDatabase       sysname         NOT NULL,
        StopAt               datetime2(3)    NULL,
        StartedAt            datetime2(3)    NOT NULL,
        RestoreFinishedAt    datetime2(3)    NULL,
        FinishedAt           datetime2(3)    NULL,
        BackupFilesRestored  int             NULL,
        RestoreSeconds       int             NULL,       -- measured recovery time
        RtoTargetSeconds     int             NULL,
        RpoExposureSeconds   int             NULL,       -- age of the newest backup when the drill started
        RpoTargetSeconds     int             NULL,
        SourceRows           bigint          NULL,
        TargetRows           bigint          NULL,
        CheckDbStatus        varchar(12)     NOT NULL CONSTRAINT DF_RestoreDrillLog_CheckDb DEFAULT ('SKIPPED'),
        ValidationStatus     varchar(12)     NOT NULL CONSTRAINT DF_RestoreDrillLog_Validation DEFAULT ('NOT RUN'),
        Status               varchar(10)     NOT NULL,
        Notes                nvarchar(1000)  NULL
    );
GO

IF OBJECT_ID(N'dba.DrillRun', N'U') IS NULL
    CREATE TABLE dba.DrillRun (
        DrillRunId      int IDENTITY(1,1) NOT NULL CONSTRAINT PK_DrillRun PRIMARY KEY,
        Scenario        varchar(40)    NOT NULL,
        KnownGoodTime   datetime2(3)   NOT NULL,   -- last moment the data was known to be correct
        IncidentTime    datetime2(3)   NOT NULL,
        Notes           nvarchar(400)  NULL
    );
GO

IF OBJECT_ID(N'dba.MaintenanceLog', N'U') IS NULL
    CREATE TABLE dba.MaintenanceLog (
        MaintenanceLogId     bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_MaintenanceLog PRIMARY KEY,
        DatabaseName         sysname         NOT NULL,
        ObjectName           nvarchar(300)   NOT NULL,
        IndexOrStatName      sysname         NULL,
        PartitionNumber      int             NULL,
        Operation            varchar(20)     NOT NULL,   -- REBUILD | REORGANIZE | UPDATE STATS
        Command              nvarchar(2000)  NOT NULL,
        PageCount            bigint          NULL,
        FragmentationBefore  decimal(5,1)    NULL,
        FragmentationAfter   decimal(5,1)    NULL,
        StartedAt            datetime2(3)    NOT NULL,
        FinishedAt           datetime2(3)    NULL,
        ErrorNumber          int             NULL,
        ErrorMessage         nvarchar(2048)  NULL
    );
GO

IF OBJECT_ID(N'dba.IntegrityCheckLog', N'U') IS NULL
    CREATE TABLE dba.IntegrityCheckLog (
        IntegrityCheckLogId  int IDENTITY(1,1) NOT NULL CONSTRAINT PK_IntegrityCheckLog PRIMARY KEY,
        DatabaseName         sysname         NOT NULL,
        PhysicalOnly         bit             NOT NULL,
        StartedAt            datetime2(3)    NOT NULL,
        FinishedAt           datetime2(3)    NOT NULL,
        Status               varchar(10)     NOT NULL,   -- CLEAN | ERRORS
        LastGoodCheckDb      datetime        NULL,
        ErrorMessage         nvarchar(2048)  NULL
    );
GO

IF OBJECT_ID(N'dba.HealthCheckResult', N'U') IS NULL
    CREATE TABLE dba.HealthCheckResult (
        HealthCheckResultId  bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_HealthCheckResult PRIMARY KEY,
        RunId                uniqueidentifier NOT NULL,
        CheckedAt            datetime2(0)     NOT NULL,
        Category             varchar(30)      NOT NULL,
        CheckName            varchar(80)      NOT NULL,
        Severity             varchar(5)       NOT NULL,  -- OK | INFO | WARN | CRIT
        Detail               nvarchar(1000)   NOT NULL
    );
GO

IF OBJECT_ID(N'dba.BlockingSnapshot', N'U') IS NULL
    CREATE TABLE dba.BlockingSnapshot (
        BlockingSnapshotId     bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_BlockingSnapshot PRIMARY KEY,
        CapturedAt             datetime2(3)    NOT NULL,
        DatabaseName           sysname         NULL,
        BlockedSessionId       int             NOT NULL,
        BlockingSessionId      int             NOT NULL,
        IsHeadBlocker          bit             NOT NULL,
        WaitType               nvarchar(60)    NULL,
        WaitTimeMs             int             NULL,
        WaitResource           nvarchar(256)   NULL,
        BlockedLogin           nvarchar(128)   NULL,
        BlockedProgram         nvarchar(128)   NULL,
        BlockedStatement       nvarchar(4000)  NULL,
        BlockingLogin          nvarchar(128)   NULL,
        BlockingProgram        nvarchar(128)   NULL,
        BlockingStatus         nvarchar(30)    NULL,
        BlockingOpenTranCount  int             NULL,
        BlockingLastBatch      nvarchar(4000)  NULL
    );
GO

IF OBJECT_ID(N'dba.WaitStatsSnapshot', N'U') IS NULL
    CREATE TABLE dba.WaitStatsSnapshot (
        CapturedAt        datetime2(3)  NOT NULL,
        WaitType          nvarchar(60)  NOT NULL,
        WaitingTasks      bigint        NOT NULL,
        WaitTimeMs        bigint        NOT NULL,
        SignalWaitTimeMs  bigint        NOT NULL,
        CONSTRAINT PK_WaitStatsSnapshot PRIMARY KEY (CapturedAt, WaitType)
    );
GO

IF OBJECT_ID(N'dba.DatabaseSizeHistory', N'U') IS NULL
    CREATE TABLE dba.DatabaseSizeHistory (
        DatabaseSizeHistoryId  bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DatabaseSizeHistory PRIMARY KEY,
        CapturedAt             datetime2(0)   NOT NULL,
        DatabaseName           sysname        NOT NULL,
        LogicalFileName        sysname        NOT NULL,
        FileType               varchar(10)    NOT NULL,
        FileGroupName          sysname        NULL,
        SizeMB                 decimal(12,1)  NOT NULL,
        UsedMB                 decimal(12,1)  NULL,
        GrowthSetting          varchar(20)    NOT NULL
    );
GO

IF OBJECT_ID(N'dba.TestResult', N'U') IS NULL
    CREATE TABLE dba.TestResult (
        TestResultId  int IDENTITY(1,1) NOT NULL CONSTRAINT PK_TestResult PRIMARY KEY,
        Suite         varchar(30)     NOT NULL,
        TestName      nvarchar(200)   NOT NULL,
        Passed        bit             NOT NULL,
        Detail        nvarchar(1000)  NULL,
        RecordedAt    datetime2(0)    NOT NULL CONSTRAINT DF_TestResult_RecordedAt DEFAULT (SYSDATETIME())
    );
GO

-- Before and after measurements from the performance labs.
IF OBJECT_ID(N'lab.PerfResult', N'U') IS NULL
    CREATE TABLE lab.PerfResult (
        PerfResultId  int IDENTITY(1,1) NOT NULL CONSTRAINT PK_PerfResult PRIMARY KEY,
        Lab           varchar(40)     NOT NULL,
        Phase         varchar(20)     NOT NULL,   -- before | after | after_psp
        Metric        varchar(40)     NOT NULL,
        Value         decimal(18,2)   NOT NULL,
        Detail        nvarchar(400)   NULL,
        CapturedAt    datetime2(3)    NOT NULL CONSTRAINT DF_PerfResult_CapturedAt DEFAULT (SYSDATETIME())
    );
GO

CREATE OR ALTER PROCEDURE dba.usp_Assert
    @Suite   varchar(30),
    @Name    nvarchar(200),
    @Passed  bit,
    @Detail  nvarchar(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    INSERT dba.TestResult (Suite, TestName, Passed, Detail)
    VALUES (@Suite, @Name, ISNULL(@Passed, 0), @Detail);

    PRINT CASE WHEN ISNULL(@Passed, 0) = 1 THEN N'PASS  ' ELSE N'FAIL  ' END
        + @Suite + N' : ' + @Name
        + CASE WHEN @Detail IS NULL THEN N'' ELSE N'  (' + @Detail + N')' END;
END;
GO
