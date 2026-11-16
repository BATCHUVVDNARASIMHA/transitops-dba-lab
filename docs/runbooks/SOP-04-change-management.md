# SOP-04: Change management and code promotion

How a schema change gets from a developer's request to production.

## Rules

1. Every change is a numbered migration file: `V<nnn>__<description>.sql`.
2. Every migration ships with a rollback file: `R<nnn>__<description>.sql`.
3. Migration files contain no `USE` statement. The same file is applied to TEST and
   then to production; the runner chooses the database.
4. An applied migration is never edited. Its SHA-256 is stored in
   `dbo.SchemaVersion` and the runner stops if the file no longer matches. Mistakes
   are corrected with a new migration.
5. Nothing reaches production that has not been applied, validated and rolled back in TEST.

## Reviewing a migration (what the DBA looks for)

| Question | Why |
|---|---|
| Does it rewrite a large table or hold a schema lock for long? | Adding a NOT NULL column with a default, changing a data type and building an index offline all block users. Prefer expand, backfill, contract and `ONLINE = ON`. |
| Is the backfill batched? | One huge UPDATE bloats the log and blocks. |
| Are constraints named and created trusted? | Unnamed constraints differ between environments. `WITH NOCHECK` leaves constraints the optimizer cannot use. |
| Does a new index duplicate an existing one? | Check `dba.usp_IndexUsageReport` first. |
| Does new code filter on a function of a column or mismatched data types? | See performance labs 2 and 3. |
| Does the rollback actually reverse it, and what happens to data written in between? | Dropping a column is not undone by adding it back. |

## Promotion procedure

`scripts/migrate.sh` performs these steps. By hand they are:

1. Refresh TEST from production if it is stale (SOP-01, section 6).
2. Apply pending migrations to `TransitOps_TEST`. Run `validate.sql`.
3. Run the rollback of the newest migration in TEST. Confirm the schema is back.
   Reapply.
4. Take a `COPY_ONLY` full backup of production.
5. Apply the same files to `TransitOps` in the agreed window. Run `validate.sql`.
6. Confirm `dbo.SchemaVersion` matches between TEST and production.
7. Watch Query Store for regressions the next day.

## Emergency changes

An emergency fix follows the same steps with a shorter timeline: it is still a
numbered migration, still applied to TEST first, still backed up before. What can be
skipped is the waiting, not the record. An undocumented hot fix is how TEST and
production drift apart.

## Audit trail

Every DDL statement in TransitOps is captured by the database audit specification
(`SCHEMA_OBJECT_CHANGE_GROUP`), so the change record can be checked against what
actually ran and by whom.
