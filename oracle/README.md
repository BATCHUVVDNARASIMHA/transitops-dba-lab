# Oracle companion lab

The SQL Server lab is the main exhibit. This folder repeats the core
administration tasks on Oracle Database, on a subset of the same transit schema,
so the two platforms can be compared task by task.

| Task | Script | What it shows |
|---|---|---|
| Schema build | `sql/01_schema.sql` | Dedicated tablespace, schema-only owner account, interval partitioning by month |
| Security and audit | `sql/02_security.sql` | Password profile, least-privilege roles, unified audit policies on personal data |
| Logical recovery | `sql/03_incident_flashback.sql` | The same "UPDATE without WHERE" incident, repaired with Flashback Query and Flashback Table |
| Tuning | `sql/04_tuning.sql` | Execution plan before and after a local index, with DBMS_XPLAN |
| Backup and validation | `rman/backup_and_validate.sh` | ARCHIVELOG mode, level 0 and level 1 incremental backups, `RESTORE ... VALIDATE` |
| Monitoring | `sql/05_monitoring.sql` | Tablespace usage, blocking sessions, top SQL, RMAN history, audit trail |

## Run it

Requires Docker and the Oracle Database Free image (several GB on first pull).

```
cd oracle
cp .env.example .env
docker compose up -d
docker compose exec -T oracle bash /lab/run.sh
```

The first start creates the database and takes a few minutes. Wait until
`docker compose logs oracle` shows `DATABASE IS READY TO USE!` before running the lab.

## Scope and limits

- Single instance, one pluggable database (FREEPDB1). Real Application Clusters and
  E-Business Suite cannot run in a laptop container. The commands and checks for those
  environments are written up in [docs/platform-parity.md](../docs/platform-parity.md)
  as reference notes, and are labelled as such.
- This module is run by hand. The GitHub Actions workflow covers the SQL Server lab only.
- The scripts connect as SYSTEM, not SYS. Flashback is not available to SYS, and
  routine administration should not use SYS in any case.
