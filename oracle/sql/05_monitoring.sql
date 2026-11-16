-- 05_monitoring.sql
-- Daily health queries. Each one has a direct SQL Server counterpart in
-- DBAdmin.dba.usp_HealthCheck; see docs/platform-parity.md.

SET FEEDBACK OFF VERIFY OFF LINESIZE 200 PAGESIZE 100

PROMPT Instance and database
SELECT instance_name, version_full, status, TO_CHAR(startup_time, 'YYYY-MM-DD HH24:MI') AS started FROM v$instance;
SELECT name, log_mode, open_mode FROM v$database;

PROMPT Tablespace usage (percent of maximum size)
SELECT tablespace_name, ROUND(used_percent, 1) AS used_pct
FROM dba_tablespace_usage_metrics
ORDER BY used_percent DESC;

PROMPT Blocked sessions and who blocks them
SELECT sid, serial#, username, blocking_session, event, seconds_in_wait
FROM v$session
WHERE blocking_session IS NOT NULL;

PROMPT Top statements by elapsed time
SELECT *
FROM (SELECT sql_id, executions, ROUND(elapsed_time / 1000000, 2) AS elapsed_s, buffer_gets,
             SUBSTR(sql_text, 1, 70) AS sql_text
      FROM v$sqlstats
      ORDER BY elapsed_time DESC)
WHERE ROWNUM <= 10;

PROMPT Invalid objects
SELECT owner, object_type, object_name
FROM dba_objects
WHERE status = 'INVALID' AND owner = 'TRANSITOPS';

PROMPT RMAN job history
SELECT TO_CHAR(start_time, 'YYYY-MM-DD HH24:MI') AS started, input_type, status,
       ROUND(output_bytes / 1048576) AS output_mb, time_taken_display
FROM v$rman_backup_job_details
ORDER BY start_time DESC
FETCH FIRST 10 ROWS ONLY;

PROMPT Recent audit records for the operator table
SELECT TO_CHAR(event_timestamp, 'YYYY-MM-DD HH24:MI:SS') AS at, dbusername, action_name, object_name
FROM unified_audit_trail
WHERE object_schema = 'TRANSITOPS' AND object_name = 'OPERATOR'
ORDER BY event_timestamp DESC
FETCH FIRST 10 ROWS ONLY;

EXIT
