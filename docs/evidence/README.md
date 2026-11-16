# Evidence

`lab-report.md` in this folder is written by the lab itself:

```
.\lab.ps1 report        # Windows PowerShell
make report             # macOS, Linux
```

It contains the backup log, restore drill timings against RTO and RPO, before and
after measurements from every performance lab, index maintenance results, archiving
counts, schema versions, the latest health check and every test assertion.

The GitHub Actions workflow produces the same report on every push and shows it in
the run summary.
