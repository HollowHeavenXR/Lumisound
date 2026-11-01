# Sets up the Lumisound Discord Rich Presence daemon to run at login on Windows.
#
# Uses the Rust daemon binary (lumisound-discord-rpc.exe). Previously required Python 3 ("Add python.exe
# to PATH" during install).
#
# Usage (in PowerShell):
#   .\install-windows.ps1                              # sign in with email/username + password
#   .\install-windows.ps1 -Token "<rpc_token>"          # or paste a token
#   .\install-windows.ps1 -BridgeUrl "https://..."      # self-hosted bridge
#
# Signing in is the default: the Rich Presence token is 248 characters and
# pasting it into a PowerShell window — which wraps and can mangle long lines —
# was the most error-prone step of setup. Your password is exchanged for a
# 365-day token and is never written to disk (see `lumisound-discord-rpc login`).

param(
    [string]$Token = "",
    [string]$BridgeUrl = "",
    [string]$Identifier = ""
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# The daemon is a single Rust binary (rust/rpc): a downloaded release
# lumisound-discord-rpc.exe next to this script, one on PATH, or built here
# with cargo.
$Bin = Join-Path $ScriptDir "lumisound-discord-rpc.exe"
if (-not (Test-Path $Bin)) {
    $OnPath = (Get-Command lumisound-discord-rpc -ErrorAction SilentlyContinue).Path
    if ($OnPath) {
        $Bin = $OnPath
    } elseif ((Get-Command cargo -ErrorAction SilentlyContinue) -and (Test-Path (Join-Path $ScriptDir "..\rust\rpc\Cargo.toml"))) {
        Write-Host "Building lumisound-discord-rpc with cargo (one time)..."
        Push-Location (Join-Path $ScriptDir "..\rust")
        cargo build --release -p lumisound-rpc
        Pop-Location
        Copy-Item (Join-Path $ScriptDir "..\rust\target\release\lumisound-discord-rpc.exe") $Bin
    } else {
        Write-Error "lumisound-discord-rpc.exe not found. Download it from the Lumisound GitHub releases into $ScriptDir, or install Rust (https://rustup.rs)."
        exit 1
    }
}
$LoginArgs = @("login")
if ($Token) { $LoginArgs += @("--token", $Token) }
if ($BridgeUrl) { $LoginArgs += @("--bridge-url", $BridgeUrl) }
if ($Identifier) { $LoginArgs += @("--identifier", $Identifier) }
& $Bin @LoginArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "Sign-in failed; the scheduled task was not registered."
    exit $LASTEXITCODE
}
$Action = New-ScheduledTaskAction -Execute $Bin
$Trigger = New-ScheduledTaskTrigger -AtLogOn
$Settings = New-ScheduledTaskSettingsSet -Hidden -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Days 0)
Register-ScheduledTask -TaskName "LumisoundDiscordRPC" -Action $Action -Trigger $Trigger -Settings $Settings -Force | Out-Null

Write-Host "Registered scheduled task 'LumisoundDiscordRPC' (runs at login)."
Write-Host "Starting it now..."
Start-ScheduledTask -TaskName "LumisoundDiscordRPC"

Write-Host ""
Write-Host "Check status with:"
Write-Host "  Get-ScheduledTask -TaskName LumisoundDiscordRPC"
Write-Host "Stop it with:"
Write-Host "  Stop-ScheduledTask -TaskName LumisoundDiscordRPC; Unregister-ScheduledTask -TaskName LumisoundDiscordRPC -Confirm:`$false"
