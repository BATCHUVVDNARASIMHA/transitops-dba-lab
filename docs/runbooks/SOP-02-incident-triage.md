# SOP-02: Incident triage

First response for the problems a DBA is paged for. The goal of the first ten
minutes is to capture evidence and restore service, in that order where possible.
Diagnose the root cause afterwards from what was captured.

## Blocking ("the application is frozen")

1. Capture before touching anything:
   `EXEC DBAdmin.dba.usp_CaptureBlocking @MinWaitMs = 1000;`
2. Find the head blocker (`IsHeadBlocker = 1`). Look at its status and open
   transaction count. A sleeping session with an open transaction is an application
   that forgot to commit.
3. Contact the owner of that session. Kill it only with agreement or when the
   business impact justifies it: `KILL <session_id>;` rolls its work back, and a large
   rollback takes as long as the work did.
4. Afterwards: read the blocked process reports in the `DBA_Concurrency` Extended
   Events session, identify the transaction that held locks too long, and fix that.
   `READ_COMMITTED_SNAPSHOT` removes reader and writer blocking but not writer and writer.

## Deadlocks (error 1205)

1. `EXEC DBAdmin.dba.usp_GetDeadlocks;` shows each process, the statement it ran,
   the lock it wanted and which one was the victim.
2. Look for two code paths that touch the same tables in opposite order, or a lookup
   that needs an index to avoid scanning locked rows.
3. Fixes, in order of preference: consistent lock order, shorter transactions, a
   covering index, retry logic for error 1205. See performance lab 6.

## Transaction log full (error 9002)

1. `SELECT name, log_reuse_wait_desc FROM sys.databases;` says what is preventing reuse.
2. `LOG_BACKUP`: the log backup job has stopped. Run a log backup, then fix the job.
3. `ACTIVE_TRANSACTION`: find it with `DBCC OPENTRAN` and deal with the session.
4. Only if the disk is full and nothing else works: add a second log file on another
   volume temporarily. Do not switch to SIMPLE recovery: that breaks the log chain
   and the RPO until the next full backup.

## tempdb full

1. `sys.dm_db_session_space_usage` and `sys.dm_db_task_space_usage` show who is using it.
2. Large internal objects mean sorts and hash joins spilling: a query problem.
   A large version store means a long-running transaction under snapshot isolation.
3. Stop the offending query. Restarting the instance clears tempdb but also clears
   the evidence, so it is the last resort.

## High CPU or "everything is slow"

1. `EXEC DBAdmin.dba.usp_CaptureWaitStats;` twice, a minute apart, then
   `EXEC DBAdmin.dba.usp_WaitStatsDelta;` to see what the instance waited on.
2. `EXEC DBAdmin.dba.usp_QueryStoreTopQueries @DatabaseName = N'TransitOps';`
   Look for a query whose plan changed recently.
3. A regressed plan can be forced back in Query Store as a stopgap. Find out why it
   changed (statistics, parameter sniffing, a dropped index) before closing the incident.

## Corruption (CHECKDB errors, error 823, 824 or 825)

1. Do not detach, do not restart, do not run `REPAIR_ALLOW_DATA_LOSS`.
2. Save the full CHECKDB output. Check `msdb.dbo.suspect_pages`.
3. Check the storage and the operating system logs: corruption is almost always hardware.
4. If the damage is in a nonclustered index, rebuild that index. Otherwise restore:
   page restore for a few pages, full restore to the point of failure for more.
   The log chain makes this possible with no data loss.
5. Escalate to the manager immediately. This is a severity 1 incident.

## Severity and escalation

See SOP-05 for severity levels and who is called when.
