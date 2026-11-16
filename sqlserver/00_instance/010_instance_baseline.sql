/*
    010_instance_baseline.sql

    Instance configuration baseline. These are the settings a DBA reviews on a new
    instance instead of accepting the installer defaults. Values are derived from the
    host where possible, so the script behaves the same on a laptop container and on
    a larger server.
*/
SET NOCOUNT ON;
USE master;
GO

EXEC sys.sp_configure N'show advanced options', 1;
RECONFIGURE WITH OVERRIDE;
GO

DECLARE @PhysicalMemoryMB int,
        @Cores            int,
        @MaxMemoryMB      int,
        @Maxdop           int;

SELECT @PhysicalMemoryMB = CAST(si.physical_memory_kb / 1024 AS int),
       @Cores            = si.cpu_count
FROM sys.dm_os_sys_info AS si;

-- Max server memory: the default (2147483647 MB) lets the buffer pool starve the OS.
-- Keep 25 percent back on small hosts and a flat 4 GB on larger ones.
SET @MaxMemoryMB = CASE
                       WHEN @PhysicalMemoryMB <= 16384 THEN (@PhysicalMemoryMB * 3) / 4
                       ELSE @PhysicalMemoryMB - 4096
                   END;
IF @MaxMemoryMB < 1024 SET @MaxMemoryMB = 1024;

-- MAXDOP: logical cores, capped at 8. The default of 0 lets one query take every core.
SET @Maxdop = CASE WHEN @Cores > 8 THEN 8 ELSE @Cores END;

EXEC sys.sp_configure N'max server memory (MB)', @MaxMemoryMB;
EXEC sys.sp_configure N'max degree of parallelism', @Maxdop;

-- The default cost threshold of 5 dates from the 1990s and sends trivial queries parallel.
EXEC sys.sp_configure N'cost threshold for parallelism', 50;

-- Cache a small stub on first execution of an ad hoc statement instead of a full plan.
EXEC sys.sp_configure N'optimize for ad hoc workloads', 1;

-- Backups: compress and checksum by default, so a forgotten option cannot weaken them.
EXEC sys.sp_configure N'backup compression default', 1;
EXEC sys.sp_configure N'backup checksum default', 1;

-- Dedicated admin connection from a remote host: the way in when the instance is unresponsive.
EXEC sys.sp_configure N'remote admin connections', 1;

-- Emit a blocked process report for anything blocked five seconds or longer.
-- The DBA_Concurrency Extended Events session collects these reports.
EXEC sys.sp_configure N'blocked process threshold (s)', 5;

RECONFIGURE WITH OVERRIDE;
GO

-- Trace flag 3226: stop writing a message to the error log for every successful backup.
-- With log backups every 15 minutes those messages bury real errors.
-- Set at runtime here. On a permanent instance add it as a startup parameter
-- (-T3226 on Windows, "mssql-conf traceflag 3226 on" on Linux).
DBCC TRACEON (3226, -1) WITH NO_INFOMSGS;
GO

SELECT c.name                        AS setting,
       CAST(c.value_in_use AS bigint) AS value_in_use
FROM sys.configurations AS c
WHERE c.name IN (N'max server memory (MB)',
                 N'max degree of parallelism',
                 N'cost threshold for parallelism',
                 N'optimize for ad hoc workloads',
                 N'backup compression default',
                 N'backup checksum default',
                 N'remote admin connections',
                 N'blocked process threshold (s)')
ORDER BY c.name;
GO
