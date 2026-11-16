/*
    170_extended_events.sql

    DBA_Concurrency: an always-on Extended Events session that records

      xml_deadlock_report      every deadlock, with the full graph
      blocked_process_report   any session blocked longer than the
                               'blocked process threshold' (5 s, set in 010_instance_baseline.sql)

    Two targets: a ring buffer for quick queries (dba.usp_GetDeadlocks) and rollover
    files that survive a restart. STARTUP_STATE = ON brings the session back after a
    restart, so the evidence exists before anyone asks for it.
*/
SET NOCOUNT ON;
USE master;
GO

IF EXISTS (SELECT 1 FROM sys.server_event_sessions AS s WHERE s.name = N'DBA_Concurrency')
    DROP EVENT SESSION DBA_Concurrency ON SERVER;
GO

CREATE EVENT SESSION DBA_Concurrency ON SERVER
    ADD EVENT sqlserver.xml_deadlock_report,
    ADD EVENT sqlserver.blocked_process_report
    ADD TARGET package0.ring_buffer (SET max_memory = (8192)),
    ADD TARGET package0.event_file  (SET filename = N'DBA_Concurrency.xel', max_file_size = (20), max_rollover_files = (5))
    WITH (MAX_MEMORY = 8192 KB,
          EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
          MAX_DISPATCH_LATENCY = 1 SECONDS,
          STARTUP_STATE = ON);
GO

ALTER EVENT SESSION DBA_Concurrency ON SERVER STATE = START;
GO
