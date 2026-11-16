/*
    100_create_dbadmin.sql

    DBAdmin is the DBA team's own database: configuration, policies, run logs and
    the procedures that do the work. Keeping the toolkit out of master and out of the
    application databases means it survives an application restore and can be
    deployed the same way on every instance.
*/
SET NOCOUNT ON;
USE master;
GO

IF DB_ID(N'DBAdmin') IS NULL
BEGIN
    CREATE DATABASE DBAdmin;
    ALTER DATABASE DBAdmin SET RECOVERY SIMPLE;
    ALTER DATABASE DBAdmin SET PAGE_VERIFY CHECKSUM;
    ALTER DATABASE DBAdmin MODIFY FILE (NAME = N'DBAdmin',     SIZE = 128MB, FILEGROWTH = 64MB);
    ALTER DATABASE DBAdmin MODIFY FILE (NAME = N'DBAdmin_log', SIZE = 64MB,  FILEGROWTH = 64MB);
    ALTER AUTHORIZATION ON DATABASE::DBAdmin TO sa;
END;
GO

USE DBAdmin;
GO

IF SCHEMA_ID(N'dba') IS NULL EXEC (N'CREATE SCHEMA dba AUTHORIZATION dbo;');
IF SCHEMA_ID(N'lab') IS NULL EXEC (N'CREATE SCHEMA lab AUTHORIZATION dbo;');
GO
