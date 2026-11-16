/*
    200_create_database.sql

    TransitOps: the operational database of a fictional metropolitan transit agency.
    Fare collection, fleet, operators, trips and maintenance work orders.

    Physical design decisions:
      - PRIMARY holds system objects only. User tables live in FG_DATA (the default
        filegroup), so a piecemeal restore can bring PRIMARY online first.
      - FG_FARE holds the partitioned fare tap tables: the one part of the database
        that grows without bound and gets archived by partition switching.
      - Files are pre-sized with fixed growth increments. Percentage growth produces
        larger and larger stalls as a file grows.
      - Explicit collation, so behaviour does not depend on the instance default.

    The script refuses to run if the database already exists. Dropping a database
    should never be a side effect of a deployment script; use scripts/reset.sh.
*/
SET NOCOUNT ON;
USE master;
GO

IF DB_ID(N'TransitOps') IS NOT NULL
    RAISERROR(N'TransitOps already exists. Run the reset step first if you want a clean rebuild.', 16, 1);
GO

DECLARE @DataPath nvarchar(260) = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(260)),
        @LogPath  nvarchar(260) = CAST(SERVERPROPERTY('InstanceDefaultLogPath')  AS nvarchar(260)),
        @Sep      nchar(1),
        @Sql      nvarchar(max);

SET @Sep = CASE WHEN @DataPath LIKE N'/%' THEN N'/' ELSE N'\' END;
IF RIGHT(@DataPath, 1) NOT IN (N'/', N'\') SET @DataPath = @DataPath + @Sep;
IF RIGHT(@LogPath, 1)  NOT IN (N'/', N'\') SET @LogPath  = @LogPath + @Sep;

SET @Sql = N'
CREATE DATABASE TransitOps
ON PRIMARY
    (NAME = N''TransitOps_Primary'', FILENAME = N''' + @DataPath + N'TransitOps_Primary.mdf'', SIZE = 64MB,  FILEGROWTH = 64MB),
FILEGROUP FG_DATA DEFAULT
    (NAME = N''TransitOps_Data01'',  FILENAME = N''' + @DataPath + N'TransitOps_Data01.ndf'',  SIZE = 256MB, FILEGROWTH = 128MB),
FILEGROUP FG_FARE
    (NAME = N''TransitOps_Fare01'',  FILENAME = N''' + @DataPath + N'TransitOps_Fare01.ndf'',  SIZE = 512MB, FILEGROWTH = 128MB)
LOG ON
    (NAME = N''TransitOps_Log'',     FILENAME = N''' + @LogPath  + N'TransitOps_Log.ldf'',     SIZE = 512MB, FILEGROWTH = 128MB)
COLLATE SQL_Latin1_General_CP1_CI_AS;';

EXEC sys.sp_executesql @Sql;
GO

-- SIMPLE recovery for the initial bulk load only. 250_post_load.sql switches to FULL,
-- and the first full backup in the drill starts the log chain.
ALTER DATABASE TransitOps SET RECOVERY SIMPLE;
ALTER DATABASE TransitOps SET PAGE_VERIFY CHECKSUM;
ALTER DATABASE TransitOps SET AUTO_CLOSE OFF;
ALTER DATABASE TransitOps SET AUTO_SHRINK OFF;
ALTER DATABASE TransitOps SET AUTO_CREATE_STATISTICS ON;
ALTER DATABASE TransitOps SET AUTO_UPDATE_STATISTICS ON;
ALTER DATABASE TransitOps SET TARGET_RECOVERY_TIME = 60 SECONDS;
ALTER AUTHORIZATION ON DATABASE::TransitOps TO sa;
GO
