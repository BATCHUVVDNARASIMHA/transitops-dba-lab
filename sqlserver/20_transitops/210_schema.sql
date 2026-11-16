/*
    210_schema.sql

    Schemas and tables.

      ref    reference data: modes, routes, stops, garages
      ops    operations: vehicles, operators (personal data), trips
      fare   fare collection: products, cards, taps (partitioned by month)
      maint  fleet maintenance: work orders and tasks
      app    stored procedure interface for the application service account
      rpt    reporting views (no personal data)
      sec    row-level security objects
      lab    procedures used by the performance labs

    Every constraint is named. Unnamed constraints get system-generated names that
    differ between environments and make deployment scripts fragile.
*/
SET NOCOUNT ON;
USE TransitOps;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE SCHEMA ref AUTHORIZATION dbo;
GO
CREATE SCHEMA ops AUTHORIZATION dbo;
GO
CREATE SCHEMA fare AUTHORIZATION dbo;
GO
CREATE SCHEMA maint AUTHORIZATION dbo;
GO
CREATE SCHEMA app AUTHORIZATION dbo;
GO
CREATE SCHEMA rpt AUTHORIZATION dbo;
GO
CREATE SCHEMA sec AUTHORIZATION dbo;
GO
CREATE SCHEMA lab AUTHORIZATION dbo;
GO

-- ---------------------------------------------------------------------------
-- Utility: a numbers table function for set-based data generation.
-- ---------------------------------------------------------------------------
CREATE OR ALTER FUNCTION dbo.fn_Numbers (@Count bigint)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    WITH e1 (n) AS (SELECT 1 FROM (VALUES (1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) AS v (n)),   -- 10
         e2 (n) AS (SELECT 1 FROM e1 AS a CROSS JOIN e1 AS b),                                  -- 100
         e4 (n) AS (SELECT 1 FROM e2 AS a CROSS JOIN e2 AS b),                                  -- 10,000
         e8 (n) AS (SELECT 1 FROM e4 AS a CROSS JOIN e4 AS b)                                   -- 100,000,000
    SELECT TOP (@Count) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM e8;
GO

-- ---------------------------------------------------------------------------
-- Deployment bookkeeping
-- ---------------------------------------------------------------------------
CREATE TABLE dbo.SchemaVersion (
    Version       varchar(10)    NOT NULL CONSTRAINT PK_SchemaVersion PRIMARY KEY CLUSTERED,
    Description   nvarchar(200)  NOT NULL,
    ScriptName    nvarchar(200)  NOT NULL,
    ScriptSha256  char(64)       NULL,
    AppliedBy     sysname        NOT NULL CONSTRAINT DF_SchemaVersion_AppliedBy DEFAULT (ORIGINAL_LOGIN()),
    AppliedAt     datetime2(0)   NOT NULL CONSTRAINT DF_SchemaVersion_AppliedAt DEFAULT (SYSDATETIME())
);

CREATE TABLE dbo.DrillMarker (
    DrillMarkerId          int IDENTITY(1,1) NOT NULL CONSTRAINT PK_DrillMarker PRIMARY KEY CLUSTERED,
    MarkerName             varchar(30)    NOT NULL,
    CreatedAt              datetime2(3)   NOT NULL CONSTRAINT DF_DrillMarker_CreatedAt DEFAULT (SYSDATETIME()),
    VehicleStatusChecksum  int            NULL,
    Note                   nvarchar(200)  NULL
);

CREATE TABLE dbo.ArchiveLog (
    ArchiveLogId     int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ArchiveLog PRIMARY KEY CLUSTERED,
    TableName        sysname        NOT NULL,
    MonthStart       datetime2(0)   NOT NULL,
    PartitionNumber  int            NOT NULL,
    RowsMoved        bigint         NOT NULL,
    ArchivedAt       datetime2(0)   NOT NULL CONSTRAINT DF_ArchiveLog_ArchivedAt DEFAULT (SYSDATETIME())
);
GO

-- ---------------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------------
CREATE TABLE ref.Mode (
    ModeId    tinyint      NOT NULL CONSTRAINT PK_Mode PRIMARY KEY CLUSTERED,
    ModeCode  varchar(10)  NOT NULL CONSTRAINT UQ_Mode_ModeCode UNIQUE,
    ModeName  varchar(40)  NOT NULL
);

CREATE TABLE ref.Garage (
    GarageId    int          NOT NULL CONSTRAINT PK_Garage PRIMARY KEY CLUSTERED,
    GarageCode  varchar(10)  NOT NULL CONSTRAINT UQ_Garage_GarageCode UNIQUE,
    GarageName  varchar(60)  NOT NULL
);

CREATE TABLE ref.Route (
    RouteId    int          NOT NULL CONSTRAINT PK_Route PRIMARY KEY CLUSTERED,
    RouteCode  varchar(10)  NOT NULL CONSTRAINT UQ_Route_RouteCode UNIQUE,
    RouteName  varchar(80)  NOT NULL,
    ModeId     tinyint      NOT NULL CONSTRAINT FK_Route_Mode REFERENCES ref.Mode (ModeId),
    IsActive   bit          NOT NULL CONSTRAINT DF_Route_IsActive DEFAULT (1)
);

CREATE TABLE ref.Stop (
    StopId     int           NOT NULL CONSTRAINT PK_Stop PRIMARY KEY CLUSTERED,
    StopCode   varchar(12)   NOT NULL CONSTRAINT UQ_Stop_StopCode UNIQUE,
    StopName   varchar(100)  NOT NULL,
    IsStation  bit           NOT NULL CONSTRAINT DF_Stop_IsStation DEFAULT (0),
    Latitude   decimal(9,6)  NOT NULL,
    Longitude  decimal(9,6)  NOT NULL
);

CREATE TABLE ref.RouteStop (
    RouteId       int       NOT NULL CONSTRAINT FK_RouteStop_Route REFERENCES ref.Route (RouteId),
    StopSequence  smallint  NOT NULL,
    StopId        int       NOT NULL CONSTRAINT FK_RouteStop_Stop REFERENCES ref.Stop (StopId),
    CONSTRAINT PK_RouteStop PRIMARY KEY CLUSTERED (RouteId, StopSequence)
);
GO

-- ---------------------------------------------------------------------------
-- Operations
-- ---------------------------------------------------------------------------
CREATE TABLE ops.Vehicle (
    VehicleId      int           NOT NULL CONSTRAINT PK_Vehicle PRIMARY KEY CLUSTERED,
    FleetNumber    varchar(10)   NOT NULL CONSTRAINT UQ_Vehicle_FleetNumber UNIQUE,
    ModeId         tinyint       NOT NULL CONSTRAINT FK_Vehicle_Mode REFERENCES ref.Mode (ModeId),
    GarageId       int           NOT NULL CONSTRAINT FK_Vehicle_Garage REFERENCES ref.Garage (GarageId),
    ModelYear      smallint      NOT NULL,
    Status         varchar(12)   NOT NULL CONSTRAINT CK_Vehicle_Status CHECK (Status IN ('ACTIVE', 'IN_SHOP', 'RETIRED')),
    InServiceDate  date          NOT NULL,
    LastModified   datetime2(3)  NOT NULL CONSTRAINT DF_Vehicle_LastModified DEFAULT (SYSDATETIME())
);

-- Personal data. Access is restricted, masked and audited in 30_security.
CREATE TABLE ops.Operator (
    OperatorId      int           NOT NULL CONSTRAINT PK_Operator PRIMARY KEY CLUSTERED,
    EmployeeNumber  char(7)       NOT NULL CONSTRAINT UQ_Operator_EmployeeNumber UNIQUE,
    FirstName       varchar(40)   NOT NULL,
    LastName        varchar(40)   NOT NULL,
    Email           varchar(120)  NOT NULL,
    Phone           varchar(20)   NOT NULL,
    LicenseNumber   varchar(20)   NOT NULL,
    HireDate        date          NOT NULL,
    GarageId        int           NOT NULL CONSTRAINT FK_Operator_Garage REFERENCES ref.Garage (GarageId),
    IsActive        bit           NOT NULL CONSTRAINT DF_Operator_IsActive DEFAULT (1)
);

CREATE TABLE ops.Trip (
    TripId          bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_Trip PRIMARY KEY CLUSTERED,
    ServiceDate     date          NOT NULL,
    RouteId         int           NOT NULL CONSTRAINT FK_Trip_Route REFERENCES ref.Route (RouteId),
    VehicleId       int           NOT NULL CONSTRAINT FK_Trip_Vehicle REFERENCES ops.Vehicle (VehicleId),
    OperatorId      int           NOT NULL CONSTRAINT FK_Trip_Operator REFERENCES ops.Operator (OperatorId),
    ScheduledStart  datetime2(0)  NOT NULL,
    ActualStart     datetime2(0)  NULL,
    ActualEnd       datetime2(0)  NULL,
    Status          varchar(12)   NOT NULL CONSTRAINT CK_Trip_Status CHECK (Status IN ('SCHEDULED', 'COMPLETED', 'CANCELLED'))
);
GO

-- ---------------------------------------------------------------------------
-- Fare collection
-- ---------------------------------------------------------------------------
CREATE TABLE fare.FareProduct (
    FareProductId  smallint      NOT NULL CONSTRAINT PK_FareProduct PRIMARY KEY CLUSTERED,
    ProductCode    varchar(12)   NOT NULL CONSTRAINT UQ_FareProduct_ProductCode UNIQUE,
    ProductName    varchar(60)   NOT NULL,
    Price          decimal(6,2)  NOT NULL CONSTRAINT CK_FareProduct_Price CHECK (Price >= 0)
);

CREATE TABLE fare.Card (
    CardId      int           NOT NULL CONSTRAINT PK_Card PRIMARY KEY CLUSTERED,
    CardSerial  varchar(20)   NOT NULL CONSTRAINT UQ_Card_CardSerial UNIQUE,
    IssuedDate  date          NOT NULL,
    Status      varchar(10)   NOT NULL CONSTRAINT CK_Card_Status CHECK (Status IN ('ACTIVE', 'BLOCKED', 'EXPIRED')),
    Balance     decimal(8,2)  NOT NULL CONSTRAINT DF_Card_Balance DEFAULT (0)
);
GO

-- Monthly partitions. RANGE RIGHT: each boundary value is the first instant of its month.
--   partition 1 : before 2026-05-01 (empty guard partition)
--   partition 2 : May 2026 ... partition 8 : November 2026
--   partition 9 : 2026-12-01 onward (kept empty, so adding a month is a metadata-only split)
CREATE PARTITION FUNCTION pf_TapMonthly (datetime2(0))
AS RANGE RIGHT FOR VALUES ('2026-05-01T00:00:00', '2026-06-01T00:00:00', '2026-07-01T00:00:00', '2026-08-01T00:00:00',
                           '2026-09-01T00:00:00', '2026-10-01T00:00:00', '2026-11-01T00:00:00', '2026-12-01T00:00:00');
GO

CREATE PARTITION SCHEME ps_TapMonthly
AS PARTITION pf_TapMonthly ALL TO (FG_FARE);
GO

-- The partitioning column must be part of every unique index, so the primary key
-- is (TapDateTime, TapId) and not TapId alone.
CREATE TABLE fare.Tap (
    TapId          bigint IDENTITY(1,1) NOT NULL,
    TapDateTime    datetime2(0)  NOT NULL,
    CardId         int           NOT NULL CONSTRAINT FK_Tap_Card REFERENCES fare.Card (CardId),
    StopId         int           NOT NULL CONSTRAINT FK_Tap_Stop REFERENCES ref.Stop (StopId),
    FareProductId  smallint      NOT NULL CONSTRAINT FK_Tap_FareProduct REFERENCES fare.FareProduct (FareProductId),
    Amount         decimal(6,2)  NOT NULL,
    TapType        char(1)       NOT NULL CONSTRAINT CK_Tap_TapType CHECK (TapType IN ('E', 'X', 'T')),   -- entry, exit, transfer
    CONSTRAINT PK_Tap PRIMARY KEY CLUSTERED (TapDateTime, TapId)
) ON ps_TapMonthly (TapDateTime);

-- Archive table on the same partition scheme. Because both tables share the scheme,
-- a month moves from fare.Tap to fare.TapArchive with ALTER TABLE ... SWITCH: a
-- metadata operation that takes milliseconds regardless of row count.
-- No foreign keys and no identity: archived rows must not block reference data changes.
CREATE TABLE fare.TapArchive (
    TapId          bigint        NOT NULL,
    TapDateTime    datetime2(0)  NOT NULL,
    CardId         int           NOT NULL,
    StopId         int           NOT NULL,
    FareProductId  smallint      NOT NULL,
    Amount         decimal(6,2)  NOT NULL,
    TapType        char(1)       NOT NULL,
    CONSTRAINT PK_TapArchive PRIMARY KEY CLUSTERED (TapDateTime, TapId)
) ON ps_TapMonthly (TapDateTime);
GO

-- ---------------------------------------------------------------------------
-- Fleet maintenance
-- ---------------------------------------------------------------------------
CREATE TABLE maint.WorkOrder (
    WorkOrderId  int IDENTITY(1,1) NOT NULL CONSTRAINT PK_WorkOrder PRIMARY KEY CLUSTERED,
    VehicleId    int           NOT NULL CONSTRAINT FK_WorkOrder_Vehicle REFERENCES ops.Vehicle (VehicleId),
    GarageId     int           NOT NULL CONSTRAINT FK_WorkOrder_Garage REFERENCES ref.Garage (GarageId),
    Category     varchar(20)   NOT NULL,
    Priority     tinyint       NOT NULL CONSTRAINT CK_WorkOrder_Priority CHECK (Priority BETWEEN 1 AND 4),
    Status       varchar(12)   NOT NULL CONSTRAINT CK_WorkOrder_Status CHECK (Status IN ('OPEN', 'IN_PROGRESS', 'CLOSED')),
    OpenedAt     datetime2(0)  NOT NULL,
    ClosedAt     datetime2(0)  NULL,
    Summary      varchar(200)  NOT NULL,
    CONSTRAINT CK_WorkOrder_ClosedAt CHECK (ClosedAt IS NULL OR ClosedAt >= OpenedAt)
);

CREATE TABLE maint.WorkOrderTask (
    WorkOrderTaskId  int IDENTITY(1,1) NOT NULL CONSTRAINT PK_WorkOrderTask PRIMARY KEY CLUSTERED,
    WorkOrderId      int           NOT NULL CONSTRAINT FK_WorkOrderTask_WorkOrder REFERENCES maint.WorkOrder (WorkOrderId),
    TaskCode         varchar(12)   NOT NULL,
    LaborHours       decimal(5,2)  NOT NULL,
    PartsCost        decimal(9,2)  NOT NULL
);
GO
