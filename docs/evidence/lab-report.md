# TransitOps DBA lab: evidence report

Generated 2026-11-16 06:02:07 UTC on SQL Server 16.0.4325.4 (Developer Edition (64-bit), CU28).

Every figure below was written by the lab's own procedures while it ran.

## Backups

| Database | Type | Copy only | Started | Duration (ms) | Size (MB) | Compressed (MB) | Verified | Status |
|---|---|---|---|---:|---:|---:|---|---|
| TransitOps | FULL | no | 2026-11-16 06:00:23 | 739 | 148.09 | 38.52 | yes | SUCCEEDED |
| TransitOps | LOG | no | 2026-11-16 06:00:24 | 57 | 2.90 | 0.83 | yes | SUCCEEDED |
| TransitOps | DIFF | no | 2026-11-16 06:00:24 | 109 | 6.09 | 1.02 | yes | SUCCEEDED |
| TransitOps | LOG | no | 2026-11-16 06:00:24 | 65 | 5.59 | 1.47 | yes | SUCCEEDED |
| master | FULL | no | 2026-11-16 06:00:24 | 73 | 4.09 | 0.79 | yes | SUCCEEDED |
| msdb | FULL | no | 2026-11-16 06:00:24 | 110 | 16.09 | 2.54 | yes | SUCCEEDED |
| model | FULL | no | 2026-11-16 06:00:24 | 70 | 2.77 | 0.47 | yes | SUCCEEDED |
| DBAdmin | FULL | no | 2026-11-16 06:00:24 | 65 | 6.09 | 0.56 | yes | SUCCEEDED |
| TransitOps | LOG | no | 2026-11-16 06:00:33 | 45 | 0.21 | 0.05 | yes | SUCCEEDED |
| TransitOps | LOG | no | 2026-11-16 06:00:39 | 45 | 0.21 | 0.04 | yes | SUCCEEDED |
| TransitOps | LOG | no | 2026-11-16 06:00:39 | 40 | 0.09 | 0.01 | yes | SUCCEEDED |
| TransitOps | LOG | no | 2026-11-16 06:01:47 | 1661 | 370.23 | 110.57 | yes | SUCCEEDED |
| TransitOps | LOG | no | 2026-11-16 06:01:59 | 1828 | 420.29 | 116.28 | yes | SUCCEEDED |
| TransitOps | FULL | yes | 2026-11-16 06:02:02 | 1091 | 229.09 | 68.79 | yes | SUCCEEDED |
| TransitOps | LOG | no | 2026-11-16 06:02:04 | 166 | 32.34 | 6.92 | yes | SUCCEEDED |

## Restore drills

| Drill | Target | Stop at | Backup files | Restore (s) | RTO target (s) | RPO exposure (s) | RPO target (s) | CHECKDB | Validation | Status |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| PITR | TransitOps_PITR | 2026-11-16 06:00:28.014 | 4 | 6 | 3600 | 0 | 900 | SKIPPED | PASSED | SUCCEEDED |
| FULL_CHAIN | TransitOps_DRDrill | latest | 6 | 6 | 3600 | 0 | 900 | CLEAN | PASSED | SUCCEEDED |
| TEST_REFRESH | TransitOps_TEST | latest | 6 | 6 | 3600 | 8 | 900 | SKIPPED | PASSED | SUCCEEDED |

- PITR: RTO met. RPO exposure within target. Recovery point verified by markers. 624 vehicle rows repaired from the copy and verified against the pre-incident checksum.
- FULL_CHAIN: RTO met. RPO exposure within target.
- TEST_REFRESH: RTO met. RPO exposure within target. Recovery set to SIMPLE. Personal data scrubbed.

## Performance labs

| Lab | Metric | Before | After | Improvement |
|---|---|---:|---:|---:|
| LAB1_MISSING_INDEX | logical_reads | 12363 | 32 | 386.3x |
| LAB2_IMPLICIT_CONVERSION | logical_reads | 455 | 6 | 75.8x |
| LAB3_SARGABILITY | logical_reads | 6607 | 81 | 81.6x |
| LAB4_PARAMETER_SNIFFING | logical_reads | 1641726 | 6607 | 248.5x |
| LAB5_BLOCKING | reader_wait_ms | 10027 | 0 | n/a |
| LAB6_DEADLOCK | deadlocks | 1 | 0 | n/a |

Lab 4 with SQL Server 2022 Parameter Sensitive Plan optimization on: 1641726 logical reads for the hub station call.

## Index maintenance

| Table | Index | Partition | Operation | Pages | Fragmentation before (%) | Fragmentation after (%) |
|---|---|---:|---|---:|---:|---:|
| fare.Tap | PK_Tap | 2 | REBUILD | 2048 | 99.1 | 0.2 |
| fare.Tap | PK_Tap | 3 | REBUILD | 2048 | 99.0 | 0.2 |
| fare.Tap | PK_Tap | 4 | REBUILD | 2048 | 99.0 | 0.2 |
| fare.Tap | PK_Tap | 5 | REBUILD | 2048 | 99.2 | 0.2 |
| fare.Tap | PK_Tap | 6 | REBUILD | 2048 | 99.2 | 0.2 |
| fare.Tap | PK_Tap | 7 | REBUILD | 2048 | 99.4 | 0.2 |

## Integrity checks

| Database | Result | Duration (ms) |
|---|---|---:|
| DBAdmin | CLEAN | 102 |
| master | CLEAN | 239 |
| model | CLEAN | 90 |
| msdb | CLEAN | 300 |
| TransitOps | CLEAN | 3231 |
| TransitOps_TEST | CLEAN | 1117 |

## Archiving

| Table | Month archived | Partition | Rows moved by partition switch |
|---|---|---:|---:|
| fare.Tap | 2026-05 | 2 | 252714 |

## Schema versions

| Database | Version | Description | Applied | Script SHA-256 (prefix) |
|---|---|---|---|---|
| TransitOps | V001 | Baseline schema and seed data | 2026-11-16 06:00:23 |  |
| TransitOps | V002 | stop accessibility | 2026-11-16 06:02:04 | dccafa7ec7e2 |
| TransitOps | V003 | route delay reporting | 2026-11-16 06:02:04 | 13ce2dc66453 |
| TransitOps_TEST | V001 | Baseline schema and seed data | 2026-11-16 06:00:23 |  |
| TransitOps_TEST | V002 | stop accessibility | 2026-11-16 06:02:02 | dccafa7ec7e2 |
| TransitOps_TEST | V003 | route delay reporting | 2026-11-16 06:02:03 | 13ce2dc66453 |

## Health check (latest run)

| Severity | Category | Check | Detail |
|---|---|---|---|
| INFO | Capacity | Data file usage | DBAdmin: DBAdmin 5 MB used of 128 MB allocated |
| INFO | Capacity | Data file usage | TransitOps: TransitOps_Data01 57 MB used of 256 MB allocated |
| INFO | Capacity | Data file usage | TransitOps: TransitOps_Fare01 177 MB used of 512 MB allocated |
| INFO | Capacity | Data file usage | TransitOps: TransitOps_Primary 6 MB used of 64 MB allocated |
| INFO | Capacity | Data file usage | TransitOps_TEST: TransitOps_Data01 64 MB used of 256 MB allocated |
| INFO | Capacity | Data file usage | TransitOps_TEST: TransitOps_Fare01 99 MB used of 512 MB allocated |
| INFO | Capacity | Data file usage | TransitOps_TEST: TransitOps_Primary 5 MB used of 64 MB allocated |
| INFO | Concurrency | Deadlock capture | 1 deadlock(s) in the DBA_Concurrency session buffer. See dba.usp_GetDeadlocks. |
| INFO | Security | sa login | sa is enabled. Expected in this lab; disable or rename it in production. |
| INFO | Security | sysadmin members | 2 enabled sysadmin login(s). Review against the access list. |
| OK | Availability | Database state | All databases are ONLINE. |
| OK | Capacity | File growth setting | All user database files use fixed growth increments. |
| OK | Concurrency | Blocked sessions | No session has been blocked for more than 30 seconds. |
| OK | Concurrency | Long open transaction | No user transaction has been open for more than 15 minutes. |
| OK | Configuration | Auto close or auto shrink | No database uses AUTO_CLOSE or AUTO_SHRINK. |
| OK | Configuration | Backup checksum default | backup checksum default = 1 |
| OK | Configuration | Backup compression default | backup compression default = 1 |
| OK | Configuration | Cost threshold for parallelism | cost threshold for parallelism = 50 |
| OK | Configuration | Max degree of parallelism | max degree of parallelism = 4 on 4 core(s) |
| OK | Configuration | Max server memory | max server memory (MB) = 9590 |
| OK | Configuration | Remote admin connections | remote admin connections = 1 |
| OK | Configuration | tempdb data files | 4 tempdb data file(s) for 4 core(s). |
| OK | Integrity | CHECKDB in the last 7 days | DBAdmin: last clean CHECKDB 2026-11-16 06:01 |
| OK | Integrity | CHECKDB in the last 7 days | master: last clean CHECKDB 2026-11-16 06:01 |
| OK | Integrity | CHECKDB in the last 7 days | model: last clean CHECKDB 2026-11-16 06:01 |
| OK | Integrity | CHECKDB in the last 7 days | msdb: last clean CHECKDB 2026-11-16 06:01 |
| OK | Integrity | CHECKDB in the last 7 days | TransitOps: last clean CHECKDB 2026-11-16 06:01 |
| OK | Integrity | CHECKDB in the last 7 days | TransitOps_TEST: last clean CHECKDB 2026-11-16 06:01 |
| OK | Integrity | Page verify | All databases use CHECKSUM page verification. |
| OK | Integrity | Suspect pages | 0 row(s) in msdb.dbo.suspect_pages. |
| OK | Jobs | Agent job failures in 24 hours | No Agent job has failed in the last 24 hours. |
| OK | Recoverability | Backup policy compliance | DBAdmin: COMPLIANT, last full 2026-11-16 06:00 |
| OK | Recoverability | Backup policy compliance | master: COMPLIANT, last full 2026-11-16 06:00 |
| OK | Recoverability | Backup policy compliance | model: COMPLIANT, last full 2026-11-16 06:00 |
| OK | Recoverability | Backup policy compliance | msdb: COMPLIANT, last full 2026-11-16 06:00 |
| OK | Recoverability | Backup policy compliance | TransitOps: COMPLIANT, last full 2026-11-16 06:00, last log 2026-11-16 06:02 |
| OK | Recoverability | Backup policy compliance | TransitOps_TEST: EXEMPT |
| OK | Security | Password policy | Every SQL login enforces the password policy. |
| OK | Security | Server audit | 1 server audit(s) running. |
| OK | Transaction log | Log space used | No transaction log is more than 75 percent full. |
| OK | Transaction log | Virtual log files | DBAdmin: 8 VLFs |
| OK | Transaction log | Virtual log files | TransitOps: 8 VLFs |
| OK | Transaction log | Virtual log files | TransitOps_TEST: 8 VLFs |

## Tests

44 of 44 assertions passed.

| Suite | Result | Test | Detail |
|---|---|---|---|
| build | PASS | TransitOps is online, FULL recovery, CHECKSUM page verify, Query Store on | FULL recovery, page verify CHECKSUM |
| build | PASS | Fare tap volume loaded | 1560000 taps in live and archive tables |
| build | PASS | Every foreign key and check constraint is trusted | 0 untrusted |
| backup | PASS | Every backup succeeded and passed RESTORE VERIFYONLY | 14 of 14 backups succeeded and verified |
| backup | PASS | TransitOps log backup chain has no gaps | 0 gap(s) |
| backup | PASS | A COPY_ONLY backup was taken before the production deployment | 1 copy-only full backup(s) |
| backup | PASS | Every database meets its backup policy | all compliant |
| recovery | PASS | Point-in-time recovery reached the right moment and the repair was verified | SUCCEEDED, validation PASSED, 4 backup files |
| recovery | PASS | DR drill restored the full chain, CHECKDB clean, row counts match | SUCCEEDED, CHECKDB CLEAN, row counts PASSED |
| recovery | PASS | Measured recovery time is within the RTO | 6 s measured against an RTO of 3600 s |
| recovery | PASS | Drill databases were cleaned up |  |
| environments | PASS | TEST copy exists and is in SIMPLE recovery | SIMPLE |
| environments | PASS | Personal data is scrubbed in the TEST copy | 0 operator rows still carry production e-mail addresses |
| security | PASS | Reporting account is denied the operator (PII) table | error 229 |
| security | PASS | Reporting account reads reporting views across all garages | error 0, garages visible 4 |
| security | PASS | Developer sees operator e-mail masked | sees mXXX@XXXX.com |
| security | PASS | Developer cannot modify data | error 229 |
| security | PASS | HR role sees operator e-mail unmasked | error 0 |
| security | PASS | Garage supervisor sees only their own garage (row-level security) | 7385 work orders visible, all in garage 1 |
| security | PASS | Garage supervisor cannot move a work order to another garage | error 33504 |
| security | PASS | Application account can record a tap through its stored procedure | error 0 |
| security | PASS | Application account has no direct table access | error 229 |
| security | PASS | DBA I can monitor, run the health check and take backups | view server state 1, health check 1, backup 1 |
| security | PASS | DBA I is not sysadmin, cannot restore, cannot read personal data | sysadmin 0, restore 0, operator data 0 |
| security | PASS | Server audit is running |  |
| security | PASS | Audit recorded the HR read of operator personal data | 1 audit record(s) |
| performance | PASS | Lab 1: covering index cut logical reads at least 5x | 12363 reads before, 32 after |
| performance | PASS | Lab 2: matching the parameter type cut logical reads at least 5x | 455 reads before, 6 after |
| performance | PASS | Lab 3: sargable date predicate cut logical reads at least 5x | 6607 reads before, 81 after |
| performance | PASS | Lab 4: per-call compilation cut logical reads at least 5x | 1641726 reads before, 6607 after |
| performance | PASS | Lab 5: reader no longer waits behind the writer with READ_COMMITTED_SNAPSHOT | reader waited 10027 ms before, 0 ms after |
| performance | PASS | Lab 5: the blocking chain was captured while it was happening | 1 blocked session(s) captured |
| performance | PASS | READ_COMMITTED_SNAPSHOT is on for TransitOps |  |
| performance | PASS | Lab 6: deadlock captured, then eliminated by consistent lock ordering | 1 deadlock(s) with opposite lock order, 0 with consistent lock order |
| operations | PASS | Index maintenance ran on fragmented indexes without errors | 6 index operation(s), 0 error(s) |
| operations | PASS | Every rebuild reduced fragmentation | 6 of 6 rebuilds reduced fragmentation |
| operations | PASS | DBCC CHECKDB is clean on every policy database | 6 of 6 CHECKDB runs clean |
| operations | PASS | May 2026 was archived by partition switch with no rows lost | 252714 rows in the archive, 0 May rows left in the live table |
| operations | PASS | Partition for January 2027 was added ahead of time |  |
| operations | PASS | All nine DBA Agent jobs are deployed with schedules | 9 scheduled job(s) |
| operations | PASS | SQL Server Agent executed the health check job | 1 successful run(s) in job history |
| change | PASS | Migrations V002 and V003 applied to TEST and production from identical scripts | 2 of 2 migrations identical in TEST and production |
| change | PASS | Production schema contains the migrated objects |  |
| operations | PASS | Health check reports no critical findings | no critical findings |
