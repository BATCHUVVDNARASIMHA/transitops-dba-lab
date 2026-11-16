<#
.SYNOPSIS
    Runs the TransitOps DBA lab from Windows PowerShell.

.DESCRIPTION
    A thin wrapper around docker compose. All of the work happens inside the
    SQL Server container, so the only requirement on the host is Docker Desktop.

.EXAMPLE
    .\lab.ps1 all       # start the container and run the whole lab, then write the evidence report
    .\lab.ps1 perf      # run one stage
    .\lab.ps1 reset     # remove everything the lab created inside the instance
    .\lab.ps1 destroy   # stop the container and delete its volume
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('up', 'deploy', 'drill', 'perf', 'maintain', 'migrate', 'test', 'report', 'all', 'reset', 'down', 'destroy')]
    [string]$Command = 'all'
)

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

function Invoke-Checked {
    param([Parameter(Mandatory)][string[]]$Arguments)
    & docker @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "docker $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Start-Lab {
    if (-not (Test-Path -Path '.env')) {
        Copy-Item -Path '.env.example' -Destination '.env'
        Write-Host 'Created .env from .env.example'
    }
    Invoke-Checked -Arguments @('compose', 'up', '-d', '--wait')
}

function Invoke-Stage {
    param([Parameter(Mandatory)][string]$Name)
    Invoke-Checked -Arguments @('compose', 'exec', '-T', 'mssql', 'bash', "/lab/scripts/$Name.sh")
}

function Write-Report {
    $folder = Join-Path -Path $PSScriptRoot -ChildPath 'docs/evidence'
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $report = & docker compose exec -T mssql bash /lab/scripts/report.sh
    if ($LASTEXITCODE -ne 0) {
        throw "report.sh failed with exit code $LASTEXITCODE"
    }
    $path = Join-Path -Path $folder -ChildPath 'lab-report.md'
    # Write UTF-8 without a byte order mark and with LF line endings.
    [System.IO.File]::WriteAllText($path, (($report -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Wrote $path"
}

switch ($Command) {
    'up'      { Start-Lab }
    'down'    { Invoke-Checked -Arguments @('compose', 'down') }
    'destroy' { Invoke-Checked -Arguments @('compose', 'down', '-v') }
    'report'  { Write-Report }
    'all'     { Start-Lab; Invoke-Stage -Name 'all'; Write-Report }
    default   { Start-Lab; Invoke-Stage -Name $Command }
}
