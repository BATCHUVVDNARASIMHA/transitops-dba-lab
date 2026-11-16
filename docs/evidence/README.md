# Evidence

[`lab-report.md`](lab-report.md) in this folder is written by the lab itself. The
committed copy comes from the GitHub Actions run of 2026-11-16 on SQL Server 2022
(build 16.0.4325.4, CU28); its first line states when and where it was generated.

It contains the backup log, restore drill timings against RTO and RPO, before and
after measurements from every performance lab, index maintenance results, archiving
counts, schema versions, the latest health check and every test assertion.

Running the lab locally regenerates the file:

```
.\lab.ps1 report        # Windows PowerShell
make report             # macOS, Linux
```

The workflow produces the same report on every push, shows it in the run summary
and prints it in the job log.
