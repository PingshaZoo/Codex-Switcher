$ErrorActionPreference = 'Stop'
$logDir = Join-Path $env:LOCALAPPDATA 'Codex-Switcher\logs'
$logPath = Join-Path $logDir 'runtime.log'
try {
    [IO.Directory]::CreateDirectory($logDir) | Out-Null
    & (Join-Path $PSScriptRoot 'Switcher.ps1')
} catch {
    $message = [regex]::Replace(($_.Exception.ToString() + "`n" + $_.ScriptStackTrace),'sk-[A-Za-z0-9_-]+','[REDACTED]')
    try { [IO.File]::AppendAllText($logPath,([DateTimeOffset]::Now.ToString('o') + ' [FATAL] ' + $message + "`n"),(New-Object Text.UTF8Encoding($false))) } catch { }
    Write-Host ('Startup failed. Log: ' + $logPath)
    Write-Host $message
    exit 1
}
