# SOP-01: Backup, restore and disaster recovery drills

| | |
|---|---|
| Applies to | Every database listed in `DBAdmin.dba.BackupPolicy` |
| Owner | Database administration team |
| Related code | `sqlserver/10_dbadmin/120_backup.sql`, `130_restore.sql`, `sqlserver/40_backup_recovery/` |

## 1. Policy

The backup policy is data, not tribal knowledge. One row per database states the
recovery model, backup intervals, retention, RPO and RTO.

| Tier | Example | Recovery model | Full | Differential | Log | RPO | RTO |
|---|---|---|---|---|---|---|---|
| TIER1 | TransitOps | FULL | daily | every 6 h | every 15 min | 15 min | 60 min |
| TIER2 | DBAdmin | SIMPLE | daily | none | none | 24 h | 4 h |
| SYSTEM | master, msdb, model | as installed | daily or weekly | none | none | 24 h | 4 h |
| NONPROD | TransitOps_TEST | SIMPLE | exempt, refreshed from production | | | | |

RPO is the amount of data the business accepts losing. It is set by the log backup
interval. RTO is how long a restore may take. It is proven only by restoring.

## 2. Daily checks

1. `SELECT * FROM DBAdmin.dba.vw_BackupCompliance;` Every row must be COMPLIANT or EXEMPT.
2. `SELECT * FROM DBAdmin.dba.BackupLog WHERE Status <> 'SUCCEEDED';` must return nothing.
3. Agent job history for the three backup jobs shows no failures.

Any other status is an incident. `RPO AT RISK` means the log backup job has stopped:
fix it before anything else, because every minute widens the data loss window.

## 3. Taking a backup by hand

```sql
EXEC DBAdmin.dba.usp_BackupDatabase @DatabaseName = N'TransitOps', @BackupType = 'LOG';
EXEC DBAdmin.dba.usp_BackupDatabase @DatabaseName = N'TransitOps', @BackupType = 'FULL', @CopyOnly = 1;
```

Use `@CopyOnly = 1` for any out-of-schedule full backup (before a deployment, for a
copy to another team). A normal full backup resets the differential base, and the
next scheduled differential would silently depend on a file nobody is managing.

## 4. Restoring

Never restore over production as a first step. Restore to a side database, confirm
the data is what you need, then decide between a surgical repair and a swap.

```sql
-- Print the restore commands without running them
EXEC DBAdmin.dba.usp_RestoreFromHistory
     @SourceDatabase = N'TransitOps', @TargetDatabase = N'TransitOps_PITR',
     @StopAt = '2026-11-15T09:41:00', @Execute = 0;
```

Point-in-time recovery after a data error:

1. Take a log backup immediately. It captures everything up to now.
2. Establish the last moment the data was known to be good. Ask, check application
   logs, check the audit trail.
3. Restore to a side database with `@StopAt` just before that moment.
4. Verify the copy (row counts, the specific rows in question).
5. Repair production from the copy in a transaction, validate, commit.
6. Take another log backup and drop the side database.
7. Write the incident up: cause, timeline, data affected, prevention.

`sqlserver/40_backup_recovery/410` to `430` run exactly this sequence.

If the instance itself is lost: restore master first (single-user mode), then msdb,
then user databases from the newest full, differential and log backups. If the log
file of the damaged database is still readable, back up the tail of the log
`WITH NO_TRUNCATE` before anything else.

## 5. Disaster recovery drill

Run weekly by the `DBA - Restore Drill` Agent job and by hand after any change to
the backup configuration.

```sql
EXEC DBAdmin.dba.usp_RestoreDrill @SourceDatabase = N'TransitOps', @TargetDatabase = N'TransitOps_DRDrill';
SELECT TOP (5) * FROM DBAdmin.dba.RestoreDrillLog ORDER BY DrillId DESC;
```

The drill restores the full chain, runs `DBCC CHECKDB` on the copy, compares row
counts with production and records the restore time against the RTO.

| Result | Action |
|---|---|
| Status SUCCEEDED, CHECKDB CLEAN, validation PASSED, RTO met | File the result. |
| RTO MISSED | Raise with the manager: either the RTO or the backup design has to change (more frequent differentials, faster storage, smaller databases). |
| CHECKDB ERRORS | Treat as corruption in production until proven otherwise. See SOP-02. |
| Restore failed | The backup chain is broken. Take a new full backup now, then investigate. |

## 6. Refreshing TEST

```sql
EXEC DBAdmin.dba.usp_RefreshLowerEnvironment @SourceDatabase = N'TransitOps', @TargetDatabase = N'TransitOps_TEST';
```

The procedure scrubs personal data before it returns and drops the copy if the
scrub fails. An unmasked production copy must never be left in a test environment.
