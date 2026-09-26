<#
.SYNOPSIS
  LookPress backup on Windows — thin wrapper that runs scripts/backup.sh through Git Bash.

.DESCRIPTION
  All logic lives in scripts/backup.sh (and restore.sh). This wrapper only locates
  bash.exe from Git for Windows and forwards every argument unchanged, e.g.

    .\scripts\backup.ps1 --out D:\backups\lookpress --keep 14 --sidecar
    .\scripts\backup.ps1 --help

  Restore is the same idea:  & "C:\Program Files\Git\bin\bash.exe" scripts/restore.sh <archive> --yes

  Docker Desktop users: backup.sh detects the "lookpress" container automatically.
  The stock LOOK image has no sqlite3, so pass --sidecar to snapshot the SQLite DB
  online (default sidecar image python:3-alpine); without it the script stops the
  container for a second to copy the file consistently. See docs/ops-backup.md.
#>
[CmdletBinding()]
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $BackupArgs
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$backupSh  = Join-Path $scriptDir 'backup.sh'
if (-not (Test-Path $backupSh)) { Write-Error "backup.sh not found next to this wrapper: $backupSh"; exit 1 }

# Locate Git Bash (not WSL bash: docker/paths behave differently there).
$candidates = @()
$gitCmd = Get-Command git.exe -ErrorAction SilentlyContinue
if ($gitCmd) {
  $gitRoot = Split-Path -Parent (Split-Path -Parent $gitCmd.Source)   # <git>\cmd\git.exe or <git>\bin\git.exe
  $candidates += (Join-Path $gitRoot 'bin\bash.exe')
  $candidates += (Join-Path $gitRoot 'usr\bin\bash.exe')
}
$candidates += "$env:ProgramFiles\Git\bin\bash.exe"
$candidates += "${env:ProgramFiles(x86)}\Git\bin\bash.exe"
$candidates += "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"

$bash = $null
foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { $bash = $c; break } }

if (-not $bash) {
  Write-Host 'Git Bash (bash.exe) was not found.' -ForegroundColor Yellow
  Write-Host 'backup.sh needs a POSIX shell with tar/gzip. Options:'
  Write-Host '  1. Install Git for Windows (https://git-scm.com/download/win) and re-run this wrapper.'
  Write-Host '  2. Run it from WSL:   wsl bash scripts/backup.sh --out /mnt/d/backups --keep 14'
  Write-Host '     (inside WSL, docker must point at Docker Desktop for the container to be detected).'
  exit 1
}

# Forward arguments verbatim; the script converts host paths for docker itself.
$relative = 'scripts/backup.sh'
Push-Location (Split-Path -Parent $scriptDir)
try {
  & $bash $relative @BackupArgs
  exit $LASTEXITCODE
} finally {
  Pop-Location
}
