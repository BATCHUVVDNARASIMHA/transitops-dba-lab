# SOP-03: Patching and upgrades

## Principles

- Patches move through environments in order: development, test, production. The
  same build that was tested is the build that is installed.
- Every patch has a rollback plan that was thought through before the window opened.
- "Applied" is proven with the version inventory, not assumed.

## Before the window

1. Read the release notes for the cumulative update. Note fixes that touch features
   in use and any known issues.
2. Record the starting point: run `sqlserver/00_instance/020_version_inventory.sql`
   and `EXEC DBAdmin.dba.usp_HealthCheck;` and keep both outputs.
3. Confirm backups: `SELECT * FROM DBAdmin.dba.vw_BackupCompliance;` and take
   fresh full backups of master, msdb and every user database.
4. Confirm `DBCC CHECKDB` is clean and recent. Never patch on top of unknown corruption.
5. Agree the window, the rollback trigger and who makes the call.

## During the window

Stand-alone instance:

1. Stop application connections, or confirm the maintenance page is up.
2. Install the update and restart.
3. Watch the error log until every database has completed its upgrade steps and is ONLINE.

Clustered or availability group instances (rolling):

1. Patch a secondary replica or passive node first.
2. Fail over to it.
3. Patch the former primary.
4. Fail back if required, and confirm synchronisation is healthy.

## After the window

1. Run the version inventory again. The build number must match the target.
2. Run the health check and compare with the saved output.
3. Run the application smoke tests with the application team.
4. Leave Query Store on and review regressed queries the next morning. After a
   version upgrade, hold the database compatibility level until the workload has
   been observed, then raise it as a separate change.

## Rollback

| Situation | Action |
|---|---|
| Update fails to install | Fix forward or uninstall the update; databases are untouched. |
| Instance starts but the application misbehaves | Uninstall the cumulative update. System databases keep working one cumulative update back within the same major version. |
| Major version upgrade goes wrong | Restore to the old instance from the pre-upgrade backups. Databases cannot be downgraded in place. |

## Rehearsing in the lab

The container image tag is the patch level. `.env` sets `MSSQL_IMAGE_TAG`.

1. Pin a specific cumulative update tag from the Microsoft Artifact Registry tag list
   and build the lab: `.\lab.ps1 all`.
2. Record the version inventory.
3. Change the tag to a newer cumulative update and run `docker compose up -d --wait`.
   The databases live in a volume, so the new engine upgrades them on startup, just
   like an in-place patch.
4. Run the inventory again, then `.\lab.ps1 test`. The whole assertion suite is the
   post-patch validation.

## Oracle

The same discipline with different tools: `opatch lsinventory` before and after,
`opatch apply` (or `opatchauto` for Grid Infrastructure and RAC, node by node),
then `datapatch` to apply the SQL changes, then `utlrp.sql` and an invalid object
count. Under E-Business Suite, check the application certification first; see
docs/platform-parity.md.
