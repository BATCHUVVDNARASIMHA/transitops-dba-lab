-- 02_security.sql
-- Least-privilege access model and auditing. Argument 1: password for the two
-- service accounts (the runner passes the lab password).
--
--   profile            password ageing, lockout and idle timeout for service accounts
--   transit_app_rw     the application: DML on operational tables only
--   transit_report_ro  reporting: read access, and no grant at all on OPERATOR
--   unified audit      every read or change of OPERATOR (personal data), plus
--                      account and privilege changes

WHENEVER SQLERROR EXIT SQL.SQLCODE
SET FEEDBACK ON VERIFY OFF SERVEROUTPUT ON LINESIZE 200 PAGESIZE 100

DECLARE
    PROCEDURE run_if_missing (p_check IN VARCHAR2, p_ddl IN VARCHAR2) IS
        n NUMBER;
    BEGIN
        EXECUTE IMMEDIATE p_check INTO n;
        IF n = 0 THEN
            EXECUTE IMMEDIATE p_ddl;
        END IF;
    END;
BEGIN
    run_if_missing(q'[SELECT COUNT(*) FROM dba_profiles WHERE profile = 'TRANSIT_SERVICE_PROFILE']',
                   'CREATE PROFILE transit_service_profile LIMIT
                        FAILED_LOGIN_ATTEMPTS 5
                        PASSWORD_LOCK_TIME    1/24
                        PASSWORD_LIFE_TIME    90
                        PASSWORD_GRACE_TIME   7
                        IDLE_TIME             30
                        SESSIONS_PER_USER     20');

    run_if_missing(q'[SELECT COUNT(*) FROM dba_roles WHERE role = 'TRANSIT_APP_RW']',    'CREATE ROLE transit_app_rw');
    run_if_missing(q'[SELECT COUNT(*) FROM dba_roles WHERE role = 'TRANSIT_REPORT_RO']', 'CREATE ROLE transit_report_ro');

    run_if_missing(q'[SELECT COUNT(*) FROM dba_users WHERE username = 'TRANSIT_APP']',
                   'CREATE USER transit_app IDENTIFIED BY "&1" PROFILE transit_service_profile');
    run_if_missing(q'[SELECT COUNT(*) FROM dba_users WHERE username = 'TRANSIT_REPORT']',
                   'CREATE USER transit_report IDENTIFIED BY "&1" PROFILE transit_service_profile');

    run_if_missing(q'[SELECT COUNT(*) FROM audit_unified_policies WHERE policy_name = 'TRANSIT_OPERATOR_ACCESS']',
                   'CREATE AUDIT POLICY transit_operator_access
                        ACTIONS SELECT ON transitops.operator, UPDATE ON transitops.operator, DELETE ON transitops.operator');
    run_if_missing(q'[SELECT COUNT(*) FROM audit_unified_policies WHERE policy_name = 'TRANSIT_ACCOUNT_CHANGES']',
                   'CREATE AUDIT POLICY transit_account_changes
                        ACTIONS CREATE USER, ALTER USER, DROP USER, CREATE ROLE, DROP ROLE, GRANT, REVOKE');
END;
/

GRANT CREATE SESSION TO transit_app;
GRANT CREATE SESSION TO transit_report;

GRANT SELECT, INSERT, UPDATE ON transitops.vehicle  TO transit_app_rw;
GRANT SELECT, INSERT         ON transitops.fare_tap TO transit_app_rw;
GRANT SELECT                 ON transitops.garage   TO transit_app_rw;

GRANT SELECT ON transitops.vehicle  TO transit_report_ro;
GRANT SELECT ON transitops.fare_tap TO transit_report_ro;
GRANT SELECT ON transitops.garage   TO transit_report_ro;
-- transitops.operator is deliberately absent from both roles.

GRANT transit_app_rw    TO transit_app;
GRANT transit_report_ro TO transit_report;

AUDIT POLICY transit_operator_access;
AUDIT POLICY transit_account_changes;

PROMPT Object privileges held by the two roles
SELECT grantee, table_name, privilege
FROM dba_tab_privs
WHERE grantee IN ('TRANSIT_APP_RW', 'TRANSIT_REPORT_RO')
ORDER BY grantee, table_name, privilege;

PROMPT Enabled unified audit policies
SELECT policy_name, enabled_option, entity_name
FROM audit_unified_enabled_policies
WHERE policy_name LIKE 'TRANSIT%'
ORDER BY policy_name;

EXIT
