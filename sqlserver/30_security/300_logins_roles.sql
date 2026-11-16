/*
    300_logins_roles.sql

    Access model: one persona per kind of access, permissions granted to roles and
    never to individuals, least privilege throughout.

      svc_transit_app          application service account: EXECUTE on schema app, nothing else
      svc_reporting            reporting service account: SELECT on schema rpt, denied the PII table
      dev_analyst              developer: read access, can see plans, personal data masked
      maint_supervisor_north   garage supervisor: work orders of one garage only (row-level security)
      hr_admin                 HR: the only role that sees operator personal data unmasked
      dba_junior               DBA I: monitoring and backups, no restore, no security changes

    The lab uses SQL logins because the container has no directory service. In
    production these would be Active Directory or Entra ID groups mapped to the same roles.

    Passwords are generated at deployment time and never written anywhere. Nothing in
    the lab logs in as these accounts: the tests verify permissions by impersonation.
*/
SET NOCOUNT ON;
USE master;
GO

DECLARE @Logins TABLE (LoginName sysname NOT NULL PRIMARY KEY);

INSERT @Logins (LoginName)
VALUES (N'svc_transit_app'), (N'svc_reporting'), (N'dev_analyst'),
       (N'maint_supervisor_north'), (N'hr_admin'), (N'dba_junior');

DECLARE @Name sysname, @Sql nvarchar(max);

DECLARE NewLogins CURSOR LOCAL FAST_FORWARD FOR
    SELECT l.LoginName
    FROM @Logins AS l
    WHERE NOT EXISTS (SELECT 1 FROM sys.server_principals AS sp WHERE sp.name = l.LoginName);

OPEN NewLogins;
FETCH NEXT FROM NewLogins INTO @Name;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Sql = N'CREATE LOGIN ' + QUOTENAME(@Name)
             + N' WITH PASSWORD = N''Lab-' + CONVERT(nvarchar(36), NEWID()) + N'-aZ9'''
             + N', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF, DEFAULT_DATABASE = [TransitOps];';
    EXEC sys.sp_executesql @Sql;

    FETCH NEXT FROM NewLogins INTO @Name;
END;

CLOSE NewLogins;
DEALLOCATE NewLogins;
GO

-- ---------------------------------------------------------------------------
-- Server level: a custom role for DBA I staff. They can see everything they need
-- to triage an incident and nothing that lets them change security or data.
-- ---------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.server_principals AS sp WHERE sp.name = N'srv_dba_junior' AND sp.type = 'R')
    CREATE SERVER ROLE srv_dba_junior AUTHORIZATION sa;
GO

GRANT VIEW SERVER STATE   TO srv_dba_junior;
GRANT VIEW ANY DEFINITION TO srv_dba_junior;
GRANT VIEW ANY DATABASE   TO srv_dba_junior;

IF ISNULL(IS_SRVROLEMEMBER(N'srv_dba_junior', N'dba_junior'), 0) = 0
    ALTER SERVER ROLE srv_dba_junior ADD MEMBER dba_junior;
GO

-- ---------------------------------------------------------------------------
-- TransitOps: users, roles, permissions
-- ---------------------------------------------------------------------------
USE TransitOps;
GO

CREATE USER svc_transit_app        FOR LOGIN svc_transit_app;
CREATE USER svc_reporting          FOR LOGIN svc_reporting;
CREATE USER dev_analyst            FOR LOGIN dev_analyst;
CREATE USER maint_supervisor_north FOR LOGIN maint_supervisor_north;
CREATE USER hr_admin               FOR LOGIN hr_admin;
CREATE USER dba_junior             FOR LOGIN dba_junior;
GO

CREATE ROLE role_app_execute           AUTHORIZATION dbo;
CREATE ROLE role_reporting_read        AUTHORIZATION dbo;
CREATE ROLE role_developer_read        AUTHORIZATION dbo;
CREATE ROLE role_maint_supervisor      AUTHORIZATION dbo;
CREATE ROLE role_hr_admin              AUTHORIZATION dbo;
CREATE ROLE role_workorder_all_garages AUTHORIZATION dbo;   -- members bypass the garage filter in 310_data_protection.sql
GO

-- Application: stored procedures only. No table permissions at all.
GRANT EXECUTE ON SCHEMA::app TO role_app_execute;

-- Reporting: views only, and an explicit DENY on the personal data table so a later
-- over-broad GRANT cannot expose it. DENY wins over GRANT.
GRANT SELECT ON SCHEMA::rpt TO role_reporting_read;
DENY  SELECT ON OBJECT::ops.Operator TO role_reporting_read;

-- Developers: read everything, read plans, change nothing. Masked columns stay masked.
GRANT SELECT ON SCHEMA::ref   TO role_developer_read;
GRANT SELECT ON SCHEMA::ops   TO role_developer_read;
GRANT SELECT ON SCHEMA::fare  TO role_developer_read;
GRANT SELECT ON SCHEMA::maint TO role_developer_read;
GRANT SELECT ON SCHEMA::rpt   TO role_developer_read;
GRANT VIEW DEFINITION         TO role_developer_read;
GRANT SHOWPLAN                TO role_developer_read;

-- Garage supervisors: their work orders, the vehicles those refer to.
GRANT SELECT, UPDATE ON OBJECT::maint.WorkOrder     TO role_maint_supervisor;
GRANT SELECT         ON OBJECT::maint.WorkOrderTask TO role_maint_supervisor;
GRANT SELECT         ON OBJECT::ops.Vehicle         TO role_maint_supervisor;

-- HR: operator records, unmasked.
GRANT SELECT, UPDATE ON OBJECT::ops.Operator TO role_hr_admin;
GRANT UNMASK TO role_hr_admin;
GO

ALTER ROLE role_app_execute      ADD MEMBER svc_transit_app;
ALTER ROLE role_reporting_read   ADD MEMBER svc_reporting;
ALTER ROLE role_developer_read   ADD MEMBER dev_analyst;
ALTER ROLE role_maint_supervisor ADD MEMBER maint_supervisor_north;
ALTER ROLE role_hr_admin         ADD MEMBER hr_admin;

-- The application, reporting and developers legitimately work across all garages.
ALTER ROLE role_workorder_all_garages ADD MEMBER role_app_execute;
ALTER ROLE role_workorder_all_garages ADD MEMBER role_reporting_read;
ALTER ROLE role_workorder_all_garages ADD MEMBER role_developer_read;

-- DBA I can take backups of this database. Membership in db_backupoperator grants
-- BACKUP DATABASE and BACKUP LOG and no access to data.
ALTER ROLE db_backupoperator ADD MEMBER dba_junior;
GO

-- ---------------------------------------------------------------------------
-- DBAdmin: the junior DBA can run diagnostics and backups, not restores.
-- ---------------------------------------------------------------------------
USE DBAdmin;
GO

IF DATABASE_PRINCIPAL_ID(N'dba_junior') IS NULL
    CREATE USER dba_junior FOR LOGIN dba_junior;

IF DATABASE_PRINCIPAL_ID(N'role_dba_operator') IS NULL
    CREATE ROLE role_dba_operator AUTHORIZATION dbo;
GO

GRANT SELECT  ON SCHEMA::dba TO role_dba_operator;
GRANT EXECUTE ON OBJECT::dba.usp_HealthCheck          TO role_dba_operator;
GRANT EXECUTE ON OBJECT::dba.usp_CaptureBlocking      TO role_dba_operator;
GRANT EXECUTE ON OBJECT::dba.usp_GetDeadlocks         TO role_dba_operator;
GRANT EXECUTE ON OBJECT::dba.usp_CaptureWaitStats     TO role_dba_operator;
GRANT EXECUTE ON OBJECT::dba.usp_WaitStatsDelta       TO role_dba_operator;
GRANT EXECUTE ON OBJECT::dba.usp_CaptureDatabaseSize  TO role_dba_operator;
GRANT EXECUTE ON OBJECT::dba.usp_IndexUsageReport     TO role_dba_operator;
GRANT EXECUTE ON OBJECT::dba.usp_QueryStoreTopQueries TO role_dba_operator;
GRANT EXECUTE ON OBJECT::dba.usp_BackupDatabase       TO role_dba_operator;
-- Deliberately not granted: usp_RestoreFromHistory, usp_RestoreDrill,
-- usp_RefreshLowerEnvironment, usp_IndexMaintenance, usp_PurgeHistory, usp_DeployJob.
-- Those are escalations to a DBA II.

IF ISNULL(IS_ROLEMEMBER(N'role_dba_operator', N'dba_junior'), 0) = 0
    ALTER ROLE role_dba_operator ADD MEMBER dba_junior;
GO
