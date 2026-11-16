/*
    020_version_inventory.sql

    Build and platform inventory. Run before and after every patch:
    the "after" output is the proof that the cumulative update was applied.
    See docs/runbooks/SOP-03-patching-and-upgrades.md.
*/
SET NOCOUNT ON;
USE master;
GO

SELECT p.Property, p.Value
FROM sys.dm_os_host_info AS h
CROSS JOIN sys.dm_os_sys_info AS si
CROSS APPLY (VALUES
    (N'Server name',        CAST(SERVERPROPERTY('ServerName')             AS nvarchar(256))),
    (N'Edition',            CAST(SERVERPROPERTY('Edition')                AS nvarchar(256))),
    (N'Product version',    CAST(SERVERPROPERTY('ProductVersion')         AS nvarchar(256))),
    (N'Product level',      CAST(SERVERPROPERTY('ProductLevel')           AS nvarchar(256))),
    (N'Cumulative update',  CAST(SERVERPROPERTY('ProductUpdateLevel')     AS nvarchar(256))),
    (N'Update reference',   CAST(SERVERPROPERTY('ProductUpdateReference') AS nvarchar(256))),
    (N'Server collation',   CAST(SERVERPROPERTY('Collation')              AS nvarchar(256))),
    (N'Host platform',      CAST(h.host_platform     AS nvarchar(256)) COLLATE DATABASE_DEFAULT),
    (N'Host distribution',  CAST(h.host_distribution AS nvarchar(256)) COLLATE DATABASE_DEFAULT),
    (N'Host release',       CAST(h.host_release      AS nvarchar(256)) COLLATE DATABASE_DEFAULT),
    (N'Logical cores',      CAST(si.cpu_count AS nvarchar(256))),
    (N'Physical memory MB', CAST(si.physical_memory_kb / 1024 AS nvarchar(256))),
    (N'Instance start',     CONVERT(nvarchar(256), si.sqlserver_start_time, 120))
) AS p (Property, Value);
GO
