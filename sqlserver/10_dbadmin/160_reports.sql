/*
    160_reports.sql

    Read-only reports used during reviews and investigations.

      usp_PermissionAudit       who can do what, at server and database level
      usp_IndexUsageReport      unused indexes and missing-index suggestions
      usp_QueryStoreTopQueries  the most expensive queries recorded by Query Store
*/
SET NOCOUNT ON;
USE DBAdmin;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ---------------------------------------------------------------------------
-- Access review. Four result sets: server role members, server permissions,
-- database role members, database permissions.
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dba.usp_PermissionAudit
    @DatabaseName sysname
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Sql nvarchar(max);

    IF DB_ID(@DatabaseName) IS NULL
    BEGIN
        RAISERROR(N'Database %s does not exist.', 16, 1, @DatabaseName);
        RETURN 1;
    END;

    -- 1. server role membership
    SELECT CAST(r.name AS nvarchar(40))      AS ServerRole,
           CAST(m.name AS nvarchar(40))      AS Member,
           CAST(m.type_desc AS nvarchar(20)) AS MemberType,
           m.is_disabled                     AS IsDisabled
    FROM sys.server_role_members AS rm
    JOIN sys.server_principals AS r ON r.principal_id = rm.role_principal_id
    JOIN sys.server_principals AS m ON m.principal_id = rm.member_principal_id
    WHERE m.name NOT LIKE N'##%'
      AND m.name NOT LIKE N'NT %'
    ORDER BY r.name, m.name;

    -- 2. explicit server permissions
    SELECT CAST(p.name AS nvarchar(40))             AS Grantee,
           CAST(p.type_desc AS nvarchar(20))        AS GranteeType,
           CAST(sp.state_desc AS nvarchar(12))      AS PermissionState,
           CAST(sp.permission_name AS nvarchar(40)) AS Permission
    FROM sys.server_permissions AS sp
    JOIN sys.server_principals AS p ON p.principal_id = sp.grantee_principal_id
    WHERE p.name NOT LIKE N'##%'
      AND p.name NOT LIKE N'NT %'
      AND p.name <> N'public'
      AND sp.class = 100
    ORDER BY p.name, sp.permission_name;

    -- 3 and 4. database role membership and explicit database permissions
    SET @Sql = N'USE ' + QUOTENAME(@DatabaseName) + N';

        SELECT CAST(r.name AS nvarchar(40))      AS DatabaseRole,
               CAST(m.name AS nvarchar(40))      AS Member,
               CAST(m.type_desc AS nvarchar(20)) AS MemberType
        FROM sys.database_role_members AS rm
        JOIN sys.database_principals AS r ON r.principal_id = rm.role_principal_id
        JOIN sys.database_principals AS m ON m.principal_id = rm.member_principal_id
        ORDER BY r.name, m.name;

        SELECT CAST(pr.name AS nvarchar(40))            AS Grantee,
               CAST(pe.state_desc AS nvarchar(12))      AS PermissionState,
               CAST(pe.permission_name AS nvarchar(30)) AS Permission,
               CAST(pe.class_desc AS nvarchar(20))      AS SecurableClass,
               CAST(CASE pe.class
                        WHEN 0 THEN DB_NAME()
                        WHEN 1 THEN OBJECT_SCHEMA_NAME(pe.major_id) + N''.'' + OBJECT_NAME(pe.major_id)
                        WHEN 3 THEN SCHEMA_NAME(pe.major_id)
                        ELSE CAST(pe.major_id AS nvarchar(20))
                    END AS nvarchar(60))                AS Securable
        FROM sys.database_permissions AS pe
        JOIN sys.database_principals AS pr ON pr.principal_id = pe.grantee_principal_id
        WHERE pr.name NOT IN (N''public'', N''dbo'', N''guest'')
          AND pe.major_id >= 0
        ORDER BY pr.name, pe.class, pe.permission_name;';

    EXEC sys.sp_executesql @Sql;

    RETURN 0;
END;
GO

-- ---------------------------------------------------------------------------
-- Index review. Usage counters reset at instance restart, so judge "unused"
-- only after a full business cycle of uptime.
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dba.usp_IndexUsageReport
    @DatabaseName sysname
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Sql nvarchar(max);

    IF DB_ID(@DatabaseName) IS NULL
    BEGIN
        RAISERROR(N'Database %s does not exist.', 16, 1, @DatabaseName);
        RETURN 1;
    END;

    SET @Sql = N'USE ' + QUOTENAME(@DatabaseName) + N';

        -- nonclustered indexes ordered by how little they are read
        SELECT CAST(OBJECT_SCHEMA_NAME(i.object_id) + N''.'' + OBJECT_NAME(i.object_id) AS nvarchar(40)) AS TableName,
               CAST(i.name AS nvarchar(50)) AS IndexName,
               ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0) AS Reads,
               ISNULL(us.user_updates, 0) AS Writes,
               sz.SizeMB
        FROM sys.indexes AS i
        JOIN sys.objects AS o ON o.object_id = i.object_id
        LEFT JOIN sys.dm_db_index_usage_stats AS us
               ON us.database_id = DB_ID() AND us.object_id = i.object_id AND us.index_id = i.index_id
        CROSS APPLY (SELECT CAST(SUM(ps.used_page_count) / 128.0 AS decimal(12,1)) AS SizeMB
                     FROM sys.dm_db_partition_stats AS ps
                     WHERE ps.object_id = i.object_id AND ps.index_id = i.index_id) AS sz
        WHERE o.type = ''U''
          AND o.is_ms_shipped = 0
          AND i.index_id > 1
          AND i.is_primary_key = 0
          AND i.is_unique_constraint = 0
        ORDER BY Reads ASC, Writes DESC;

        -- missing-index suggestions: input to a tuning decision, never something to create blindly
        SELECT TOP (15)
               CAST(REPLACE(REPLACE(mid.statement, N''['', N''''), N'']'', N'''') AS nvarchar(40)) AS TableName,
               CAST(mid.equality_columns AS nvarchar(60))   AS EqualityColumns,
               CAST(mid.inequality_columns AS nvarchar(60)) AS InequalityColumns,
               CAST(mid.included_columns AS nvarchar(80))   AS IncludedColumns,
               gs.user_seeks                                AS Seeks,
               CAST(gs.avg_user_impact AS decimal(5,1))     AS AvgImpactPct,
               CAST(gs.user_seeks * gs.avg_total_user_cost * gs.avg_user_impact / 100.0 AS decimal(18,1)) AS ImprovementMeasure
        FROM sys.dm_db_missing_index_details AS mid
        JOIN sys.dm_db_missing_index_groups AS g ON g.index_handle = mid.index_handle
        JOIN sys.dm_db_missing_index_group_stats AS gs ON gs.group_handle = g.index_group_handle
        WHERE mid.database_id = DB_ID()
        ORDER BY ImprovementMeasure DESC;';

    EXEC sys.sp_executesql @Sql;

    RETURN 0;
END;
GO

-- ---------------------------------------------------------------------------
-- Query Store: top queries by total logical reads.
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dba.usp_QueryStoreTopQueries
    @DatabaseName sysname,
    @Top          int = 10
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Sql nvarchar(max);

    IF DB_ID(@DatabaseName) IS NULL
    BEGIN
        RAISERROR(N'Database %s does not exist.', 16, 1, @DatabaseName);
        RETURN 1;
    END;

    SET @Sql = N'USE ' + QUOTENAME(@DatabaseName) + N';

        -- Query Store buffers runtime statistics in memory. Flush so the report is current.
        EXEC sys.sp_query_store_flush_db;

        SELECT TOP (@Top)
               q.query_id                                                                     AS QueryId,
               COUNT(DISTINCT p.plan_id)                                                      AS Plans,
               MAX(CAST(p.is_forced_plan AS int))                                             AS HasForcedPlan,
               SUM(rs.count_executions)                                                       AS Executions,
               CAST(SUM(rs.avg_logical_io_reads * rs.count_executions) AS bigint)             AS TotalLogicalReads,
               CAST(SUM(rs.avg_cpu_time * rs.count_executions) / 1000.0 AS decimal(18,1))     AS TotalCpuMs,
               CAST(SUM(rs.avg_duration * rs.count_executions) / 1000.0 AS decimal(18,1))     AS TotalDurationMs,
               CAST(ISNULL(OBJECT_SCHEMA_NAME(q.object_id) + N''.'' + OBJECT_NAME(q.object_id), N''ad hoc'') AS nvarchar(40)) AS ObjectName,
               CAST(REPLACE(REPLACE(LEFT(MAX(qt.query_sql_text), 100), NCHAR(13), N'' ''), NCHAR(10), N'' '') AS nvarchar(100)) AS QueryText
        FROM sys.query_store_runtime_stats AS rs
        JOIN sys.query_store_plan AS p        ON p.plan_id = rs.plan_id
        JOIN sys.query_store_query AS q       ON q.query_id = p.query_id
        JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
        GROUP BY q.query_id, q.object_id
        ORDER BY TotalLogicalReads DESC;';

    EXEC sys.sp_executesql @Sql, N'@Top int', @Top = @Top;

    RETURN 0;
END;
GO
