# SQL Server and Oracle: the same job on two platforms

A DBA who supports both platforms does the same work with different tools. This
table maps each task in the lab to its counterpart.

| Task | SQL Server (this lab) | Oracle |
|---|---|---|
| Point-in-time recoverability | FULL recovery model, log backups | ARCHIVELOG mode, archived redo logs |
| Backup tool | `BACKUP DATABASE / LOG`, `dba.usp_BackupDatabase` | RMAN (`rman/backup_and_validate.sh`) |
| Incremental strategy | Full, differential, log | Level 0, level 1 incremental, archived logs |
| Backup verification | `RESTORE VERIFYONLY`, restore drill plus `DBCC CHECKDB` | `RESTORE ... VALIDATE`, `VALIDATE DATABASE` |
| Undo a bad UPDATE | Restore to a side database with `STOPAT`, repair from the copy | Flashback Query, Flashback Table (falls back to RMAN PITR once undo is gone) |
| Integrity check | `DBCC CHECKDB` | RMAN `VALIDATE CHECK LOGICAL`, DBVERIFY |
| Job scheduler | SQL Server Agent | DBMS_SCHEDULER, or cron calling RMAN |
| Dynamic performance views | DMVs (`sys.dm_exec_requests`, `sys.dm_os_wait_stats`) | `V$` views (`V$SESSION`, `V$SYSTEM_EVENT`) |
| Query history | Query Store | AWR and ASH (Diagnostics Pack licence), Statspack without it |
| Plan stability | Query Store plan forcing, PSP optimization | SQL Plan Management baselines, adaptive cursor sharing |
| Execution plans | Actual plan, `SET STATISTICS IO` | `DBMS_XPLAN.DISPLAY_CURSOR`, `EXPLAIN PLAN` |
| Readers and writers | Readers block unless `READ_COMMITTED_SNAPSHOT` is on | Multiversion read consistency by default: readers never block |
| Deadlocks | Extended Events `xml_deadlock_report` | ORA-00060, trace file named in the alert log |
| Partition maintenance | Partition function and scheme, `SPLIT`, `SWITCH` | Interval partitioning, `EXCHANGE PARTITION` |
| Roles and least privilege | Database roles, schema-level `GRANT` | Roles, object grants, schema-only accounts |
| Password policy | `CHECK_POLICY` (Windows or Linux policy) | Profiles |
| Hide sensitive columns | Dynamic data masking, row-level security | Data Redaction and Virtual Private Database (check licensing) |
| Auditing | SQL Server Audit | Unified auditing |
| Copy production to test | Restore plus scrub procedure | Data Pump or RMAN duplicate plus scrub, or Data Masking Pack |
| High availability | Always On availability groups, failover cluster instances | Real Application Clusters, Data Guard |
| Patching | Cumulative updates | Release Updates with `opatch` and `datapatch` |

## Reference notes: RAC and E-Business Suite

These environments cannot run in a laptop container, so nothing below is exercised
by the lab. They are working notes for the checks a DBA II performs on them.

### Real Application Clusters

| Check | Command |
|---|---|
| Cluster resources at a glance | `crsctl stat res -t` |
| Clusterware health on all nodes | `crsctl check cluster -all` |
| Database and instance status | `srvctl status database -d <db_unique_name>` |
| Service placement | `srvctl status service -d <db_unique_name>` |
| Relocate a service before node maintenance | `srvctl relocate service -d <db> -s <service> -oldinst <i1> -newinst <i2>` |
| Sessions per instance | `SELECT inst_id, COUNT(*) FROM gv$session GROUP BY inst_id;` |
| Cross-instance blocking | `SELECT inst_id, sid, blocking_instance, blocking_session FROM gv$session WHERE blocking_session IS NOT NULL;` |
| ASM disk group free space | `SELECT name, total_mb, free_mb FROM v$asm_diskgroup;` |

Operating rules: connect applications through services, never to an instance name;
use `GV$` views so a problem on the other node is not missed; patch in rolling
fashion, one node at a time, after relocating services.

### E-Business Suite R12

| Task | How |
|---|---|
| Environment file | Source the run edition environment: `. EBSapps.env run` |
| Application tier status | `adopmnctl.sh status`, `admanagedsrvctl.sh status oacore_server1` |
| Concurrent managers | `SELECT concurrent_queue_name, max_processes, running_processes FROM fnd_concurrent_queues;` |
| Long-running requests | `fnd_concurrent_requests` joined to `fnd_concurrent_programs_tl`, filtered on `phase_code = 'R'` |
| Online patching cycle (R12.2) | `adop phase=prepare`, `apply`, `finalize`, `cutover`, `cleanup` |
| After configuration changes | AutoConfig: `adautocfg.sh` on each tier |
| Clone production to test | Rapid Clone: `adpreclone.pl` on source, `adcfgclone.pl` on target, then scrub and repoint |
| Invalid objects after patching | `adutlrcmp` or `utlrp.sql`, then compare the invalid object count with the pre-patch count |
| Database patches under EBS | Check the EBS certification and the consolidated patch list (ETCC) before applying any Release Update |

The database rule that matters most under EBS: do not apply a database patch,
parameter change or statistics job that is not certified for the application
version. The vendor's interoperability notes come first.
