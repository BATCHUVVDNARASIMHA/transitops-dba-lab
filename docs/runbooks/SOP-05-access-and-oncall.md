# SOP-05: Access management, on-call and escalation

## Access model

Permissions are granted to roles, never to individuals. A person or service gets
access by being added to a role.

| Role | Members | Can | Cannot |
|---|---|---|---|
| role_app_execute | application service account | execute procedures in schema app | read or write any table directly |
| role_reporting_read | reporting service account | read views in schema rpt | read ops.Operator (explicit DENY) |
| role_developer_read | developers, analysts | read all schemas, view plans | change data, see unmasked personal data |
| role_maint_supervisor | garage supervisors | read and update work orders of their own garage | see other garages (row-level security) |
| role_hr_admin | HR | read and update operator records unmasked | anything outside ops.Operator |
| srv_dba_junior, role_dba_operator | DBA I | monitor, run health checks, take backups | restore, change security, read application data |

## Handling an access request

1. The request names the person, the role and the business reason, and is approved
   by the data owner (not by the DBA and not by the requester).
2. Grant by role membership only: `ALTER ROLE role_developer_read ADD MEMBER [...];`
3. Record the ticket number. The server audit captures the membership change itself.
4. Time-limited access gets an end date and a calendar entry to remove it.

Requests for direct table permissions, `db_owner`, or `sysadmin` are refused or
redirected to a role. If no role fits, design one.

## Quarterly access review

```sql
EXEC DBAdmin.dba.usp_PermissionAudit @DatabaseName = N'TransitOps';
```

Send the output to each data owner for confirmation. Remove anything not confirmed.
Check for orphaned users and for logins exempt from the password policy (both are in
the health check).

## On-call

The on-call DBA carries the pager for one week and hands over with a written note:
open incidents, jobs that failed, anything unusual in the health check.

| Severity | Definition | Response | Examples |
|---|---|---|---|
| 1 | Production database unavailable or data integrity at risk | 15 minutes, any hour | instance down, corruption, failed restore during an outage |
| 2 | Production degraded, or recoverability at risk | 30 minutes, any hour | sustained blocking, log backups failing, replication or availability group lag |
| 3 | No user impact yet | next business day | a failed index job, a WARN in the health check, capacity trending toward full |

## Escalation

| Step | Who | When |
|---|---|---|
| 1 | DBA I on call | first response, evidence capture, known fixes from the runbooks |
| 2 | DBA II | anything involving a restore, a kill decision with business impact, a security change, corruption, or 30 minutes without progress |
| 3 | Manager, Database Administration | every severity 1; any decision to fail over, restore over production, or accept data loss |
| 4 | Vendor support | product defects, with the evidence already collected |

What a DBA II expects from an escalation: what was observed and when, what has been
captured (blocking snapshot, error log lines, health check output), what has already
been tried, and what the business impact is right now.

## After the incident

Every severity 1 and 2 incident gets a short written review within three working
days: timeline, root cause, what detection missed, and the one or two changes that
would have prevented it or shortened it. The review is about the system, not about
who was on call.
