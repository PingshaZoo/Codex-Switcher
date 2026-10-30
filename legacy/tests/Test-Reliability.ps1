param([switch]$KeepTemp)
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Switcher.ps1') -LibraryOnly
function Assert-Closed {}
$root=Join-Path $env:TEMP ('switcher-reliability-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$script:Passed=0
function Check($Condition,$Name) { if (!$Condition) { throw ('FAIL: '+$Name) }; $script:Passed++; Write-Output ('PASS: '+$Name) }
function Put($Path,$Text) { [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))|Out-Null; [IO.File]::WriteAllText($Path,$Text,$script:Utf8) }
function HomeAt($Name,$Config) { $dir=Join-Path $root $Name; Put (Join-Path $dir 'config.toml') $Config; return $dir }
function Meta($Id,$Provider) { return '{"ordinal":0,"type":"session_meta","payload":{"id":"'+$Id+'","model_provider":"'+$Provider+'"}}' }
function Fails([scriptblock]$Action,$Name) { $failed=$false; try { &$Action|Out-Null } catch { $failed=$true }; Check $failed $Name }
try {
    $a=HomeAt 'quoted' ('"model" = "gpt-example"'+"`n"+'notify = []')
    $null=Switch-Mode (Join-Path $a 'config.toml') deepseek https://example.invalid deepseek-flash dummy-old ''
    $config=[IO.File]::ReadAllText((Join-Path $a 'config.toml'))
    Check ($config -notmatch '(?m)^"model"') 'quoted root key replaced'
    Check (@(Get-DuplicateRootKeys $config).Count -eq 0) 'no duplicate keys'
    $null=Switch-Mode (Join-Path $a 'config.toml') openai '' '' '' ''
    Check ((Root-Value (Split-Config ([IO.File]::ReadAllText((Join-Path $a 'config.toml')))).Root model) -eq 'gpt-example') 'quoted official model restored'

    $b=HomeAt 'no-cache' 'notify = []'
    $null=Switch-Mode (Join-Path $b 'config.toml') deepseek https://example.invalid deepseek-flash dummy-old ''
    Fails { Switch-Mode (Join-Path $b 'config.toml') openai '' deepseek-flash '' '' } 'never select third-party model as official without cache'
    Put (Join-Path $b '.codex-global-state.json') '{"eligible_codex_model_slugs":["gpt-official"]}'
    $null=Switch-Mode (Join-Path $b 'config.toml') openai '' deepseek-flash '' ''
    Check ((Read-State (Join-Path $b 'codex-switcher')).officialModel -eq 'gpt-official') 'whitelist-only official recovery'

    $c=HomeAt 'credential' 'model = "gpt-example"'
    $null=Switch-Mode (Join-Path $c 'config.toml') deepseek https://example.invalid deepseek-flash dummy-old ''
    $kp=Join-Path $c 'codex-switcher\deepseek.key'; $before=[IO.File]::ReadAllText($kp)
    Put (Join-Path $c 'sessions\rollout-test.jsonl') (Meta good deepseek)
    Fails { Switch-Mode (Join-Path $c 'config.toml') deepseek https://second.invalid deepseek-flash dummy-new '' } 'migration failure reported'
    Check ($before -ceq [IO.File]::ReadAllText($kp)) 'credential restored on failure'
    Check ([IO.File]::ReadAllText((Join-Path $c 'codex-switcher\runtime.log')) -match '\[ERROR\]') 'failure diagnostics saved'
    Check ([IO.File]::ReadAllText((Join-Path $c 'codex-switcher\runtime.log')) -notmatch 'dummy-new|dummy-old') 'keys not logged'

    $catalogPath=Join-Path $c 'models.json'
    Copy-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'deepseek-models.json') -Destination $catalogPath
    $catalogBefore=[IO.File]::ReadAllText($catalogPath)
    Fails { Switch-Mode (Join-Path $c 'config.toml') deepseek https://example.invalid new-model dummy-new $catalogPath } 'catalog switch fails with missing database'
    Check ($catalogBefore -ceq [IO.File]::ReadAllText($catalogPath)) 'source catalog restored on failure'
    Check (![IO.File]::Exists((Join-Path $c 'codex-switcher\deepseek-models.json'))) 'new active catalog removed on failure'
    $d=HomeAt 'backup-failure' 'model = "gpt-example"'
    $null=Switch-Mode (Join-Path $d 'config.toml') deepseek https://example.invalid deepseek-flash dummy-old ''
    $null=Switch-Mode (Join-Path $d 'config.toml') openai '' '' '' ''
    Initialize-SqliteInterop
    [CodexSwitcherSqlite]::CreateEmptyStateDatabase((Join-Path $d 'state_5.sqlite'))
    $rollout=Join-Path $d 'sessions\rollout-test.jsonl'; Put $rollout (Meta good openai)
    function Copy-Item { param($LiteralPath,$Destination,[switch]$Force); if($Destination -like '*file-0.before-switch') { throw 'injected backup failure' }; Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force }
    Fails { Switch-Mode (Join-Path $d 'config.toml') deepseek https://example.invalid deepseek-flash '' '' } 'backup failure reported'
    Remove-Item Function:\Copy-Item
    Check ((Get-RolloutHeader $rollout).payload.model_provider -eq 'openai') 'backup failure leaves sessions intact'
    # Fail the final config write after sessions and keys have changed.
    $originalAtomic=(Get-Item Function:\Atomic-Write).ScriptBlock
    function Atomic-Write { param($Path,$Text); if($Path -eq (Join-Path $d 'config.toml')){throw 'injected config failure'}; &$originalAtomic $Path $Text }
    Fails { Switch-Mode (Join-Path $d 'config.toml') deepseek https://example.invalid deepseek-flash dummy-new '' } 'final write failure reported'
    Set-Item Function:\Atomic-Write $originalAtomic
    Check ((Get-RolloutHeader $rollout).payload.model_provider -eq 'openai') 'final write failure restores sessions'
    Check ((Read-State (Join-Path $d 'codex-switcher')).mode -eq 'openai') 'final write failure restores state'

    $e=HomeAt 'skip' 'notify = []'
    $db=Join-Path $e 'state_5.sqlite'; [CodexSwitcherSqlite]::CreateEmptyStateDatabase($db)
    $bad=Join-Path $e 'sessions\rollout-test.jsonl'
    Put $bad ((Meta '01a00000-0000-7000-8000-000000000001' deepseek)+"`n"+'{"type":')
    Put (Join-Path $e 'sessions\rollout-good.jsonl') (Meta good deepseek)
    $m=Migrate-AllChats $e openai gpt-example medium (Join-Path $e backup)
    Check ($m.Skipped.Count -eq 1 -and $m.DatabaseRows -eq 0) 'skipped row excluded from migrated count'
    $value = 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute("SELECT model_provider FROM threads").fetchone()[0]); c.close()' | python - $db
    Check ($LASTEXITCODE -eq 0 -and $value -eq 'deepseek') 'skipped row retains original route'


    $f=HomeAt 'monitor' ('model = "gpt-example"'+"`n"+'model_provider = "openai"')
    Put (Join-Path $f 'sessions\rollout-test.jsonl') ((Meta good deepseek)+"`n"+'{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"deepseek-flash","model_provider_id":"deepseek"}}}'+"`n"+'{"type":"token_usage_record","payload":{"response_id":"12345678-1234-1234-1234-123456789012"}}')
    $snap=Get-ProviderSnapshot $f
    Check ($snap.Conclusion -match 'deepseek' -and $snap.Conclusion -notmatch 'openai') 'monitor uses historical thread provider'
    Add-ProviderWatchLog $f $snap
    Check ([IO.File]::ReadAllText((Join-Path $f 'codex-switcher\provider-watch.log')) -match 'provider=deepseek') 'watch log uses historical thread provider'
    Write-Diagnostic ERROR 'secret=sk-do-not-log'
    Check ([IO.File]::ReadAllText($script:DiagnosticLog) -notmatch 'sk-do-not-log') 'diagnostic redaction'
    # Launcher must capture errors before Switcher can initialize its own logger.
    $launchDir=Join-Path $root 'launcher'
    [IO.Directory]::CreateDirectory($launchDir) | Out-Null
    Copy-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Start-Switcher.ps1') -Destination (Join-Path $launchDir 'Start-Switcher.ps1')
    $previousLocalAppData=$env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA=$launchDir
        $null=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $launchDir 'Start-Switcher.ps1')
        Check ($LASTEXITCODE -eq 1) 'launcher reports fatal initialization failure'
        Check ([IO.File]::ReadAllText((Join-Path $launchDir 'Codex-Switcher\logs\runtime.log')) -match '\[FATAL\]') 'launcher records startup failure'
    } finally { $env:LOCALAPPDATA=$previousLocalAppData }
    Write-Output ('PASS '+$script:Passed+'; root='+$root)
} finally {
    if(!$KeepTemp -and [IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath($env:TEMP),[StringComparison]::OrdinalIgnoreCase)){ Remove-Item -LiteralPath $root -Recurse -Force }
}