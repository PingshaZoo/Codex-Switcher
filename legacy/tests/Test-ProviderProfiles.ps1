param([switch]$KeepTemp)
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Switcher.ps1') -LibraryOnly
function Assert-Closed {}
$root=Join-Path $env:TEMP ('profiles-test-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($root)|Out-Null
$config=Join-Path $root 'config.toml';Atomic-Write $config 'notify = []'
$script:Pass=0
function Check($Condition,$Name){if(!$Condition){throw ('FAIL '+$Name)};$script:Pass++;Write-Output ('PASS '+$Name)}
try{
    $store=Get-ProfileStore $config
    Check $store.officialCaptured 'empty official roots captured'
    $a=New-ProviderProfile vendor_a 'Vendor A' https://a.invalid/v1 'model-a,model-b' 'secret-a' '' $null
    $b=New-ProviderProfile vendor_b 'Vendor B' https://b.invalid/v1 'model-c' 'secret-b' '' $null
    Set-ProviderProfile $store $a;Set-ProviderProfile $store $b
    $session=Join-Path $root 'sessions\rollout-test.jsonl';[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($session))|Out-Null
    Atomic-Write $session '{"type":"session_meta","payload":{"id":"test","model_provider":"openai"}}'
    $bytes=[IO.File]::ReadAllText($session)
    $null=Switch-ProviderProfile $config $store vendor_a
    $saved=Get-ProfileStore $config
    Check ($saved.profiles.Count -eq 2 -and $saved.selected -eq 'vendor_a') 'all profiles persist'
    Check ((@($saved.profiles|Where-Object {$_.id -eq 'vendor_a'}))[0].succeeded) 'successful switch remembered'
    Check ([IO.File]::ReadAllText($session) -ceq $bytes) 'default switch leaves history unchanged'
    Check ([IO.File]::ReadAllText((Join-Path $root 'codex-switcher\providers.json')) -notmatch 'secret-a|secret-b') 'no plaintext credential in store'
    $null=Switch-ProviderProfile $config $saved vendor_b
    Check ((Root-Value (Split-Config ([IO.File]::ReadAllText($config))).Root model_provider) -eq 'vendor_b') 'second provider applied'
    Check ([IO.File]::ReadAllText($config) -match '\[model_providers.vendor_a\]' -and [IO.File]::ReadAllText($config) -match '\[model_providers.vendor_b\]') 'both definitions retained'
    $oldA=@($saved.profiles|Where-Object {$_.id -eq 'vendor_a'})[0]
    $edited=New-ProviderProfile vendor_a 'Edited A' https://edited.invalid/v1 'model-new,model-b' 'secret-new' '' $oldA
    Set-ProviderProfile $saved $edited
    $null=Switch-ProviderProfile $config $saved vendor_a
    $saved=Get-ProfileStore $config
    Check ((@($saved.profiles|Where-Object {$_.id -eq 'vendor_a'}))[0].baseUrl -eq 'https://edited.invalid/v1') 'edited endpoint persists'
    Check ((@($saved.profiles|Where-Object {$_.id -eq 'vendor_a'}))[0].models[0] -eq 'model-new') 'edited models persist'
    $helper=Join-Path $root 'codex-switcher\profile-credential.ps1'
    $keyA=Join-Path $root 'codex-switcher\keys\vendor_a.key';$keyB=Join-Path $root 'codex-switcher\keys\vendor_b.key'
    $valueA=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $helper -EmitKey -KeyFile $keyA
    $valueB=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $helper -EmitKey -KeyFile $keyB
    Check ($valueA -eq 'secret-new' -and $valueB -eq 'secret-b') 'credential helpers use isolated updated keys'
    $null=Switch-ProviderProfile $config $saved openai
    Check (!(Root-Value (Split-Config ([IO.File]::ReadAllText($config))).Root model_provider)) 'return official without cache'
    Check ([IO.File]::ReadAllText($config) -match 'model_providers.vendor_b') 'official keeps provider definitions'
    $before=[IO.File]::ReadAllText($config);$stateBefore=[IO.File]::ReadAllText((Join-Path $root 'codex-switcher\providers.json'));$keyBefore=[IO.File]::ReadAllText($keyA)
    $originalAtomic=(Get-Item Function:\Atomic-Write).ScriptBlock
    function Atomic-Write {param($Path,$Text);if($Path -eq $config){throw 'injected config write failure'};&$originalAtomic $Path $Text}
    $failed=$false
    try{$null=Switch-ProviderProfile $config $saved vendor_a}catch{$failed=$true}
    Set-Item Function:\Atomic-Write $originalAtomic
    Check $failed 'failure propagated'
    Check ($before -ceq [IO.File]::ReadAllText($config)) 'config rollback'
    Check ($stateBefore -ceq [IO.File]::ReadAllText((Join-Path $root 'codex-switcher\providers.json'))) 'profile store rollback'
    Check ($keyBefore -ceq [IO.File]::ReadAllText($keyA)) 'credential rollback'
    # Existing DeepSeek state and encrypted key are imported, including compatibility alias.
    $legacy=Join-Path $root 'legacy';[IO.Directory]::CreateDirectory($legacy)|Out-Null
    $legacyConfig=Join-Path $legacy 'config.toml';Atomic-Write $legacyConfig 'model = "gpt-official"'
    $null=Switch-Mode $legacyConfig deepseek https://legacy.invalid 'legacy-model' 'legacy-secret' ''
    $imported=Get-ProfileStore $legacyConfig
    Check ($imported.profiles.Count -eq 1 -and $imported.profiles[0].id -eq 'deepseek') 'legacy state imported'
    $null=Switch-ProviderProfile $legacyConfig $imported deepseek
    $null=Switch-ProviderProfile $legacyConfig (Get-ProfileStore $legacyConfig) openai
    Check ([IO.File]::ReadAllText($legacyConfig) -match 'model_providers.codex_switcher_deepseek') 'legacy alias retained after repeated switches'
    $catalogSource=Join-Path $root 'external-models.json'
    Atomic-Write $catalogSource '{"models":[{"slug":"catalog-model","base_instructions":"Test","context_window":65536,"supports_reasoning_summaries":true,"use_responses_lite":true}]}'
    $catalogProfile=New-ProviderProfile catalog_vendor 'Catalog vendor' https://catalog.invalid/v1 'catalog-model' 'catalog-secret' $catalogSource $null
    Set-ProviderProfile $saved $catalogProfile
    $null=Switch-ProviderProfile $config $saved catalog_vendor
    Check ([IO.File]::ReadAllText($config) -match 'model_context_window = 65536') 'catalog context metadata applied'
    Check ([IO.File]::ReadAllText((Join-Path $root 'codex-switcher\catalogs\catalog_vendor.json')) -match 'use_responses_lite') 'custom model capabilities preserved'
    [IO.File]::Delete($catalogSource)
    $null=Switch-ProviderProfile $config (Get-ProfileStore $config) vendor_b
    $null=Switch-ProviderProfile $config (Get-ProfileStore $config) catalog_vendor
    Check ((Root-Value (Split-Config ([IO.File]::ReadAllText($config))).Root model_provider) -eq 'catalog_vendor') 'catalog remains usable without external source'
    Initialize-SqliteInterop
    [CodexSwitcherSqlite]::CreateEmptyStateDatabase((Join-Path $root 'state_5.sqlite'))
    $null=Switch-ProviderProfile $config (Get-ProfileStore $config) vendor_b -MigrateChats
    Check ((Get-RolloutHeader $session).payload.model_provider -eq 'vendor_b') 'optional history migration targets selected vendor'
    $parsed = 'import sys,tomllib; c=tomllib.load(open(sys.argv[1],"rb")); print(c["model_provider"]); print(c["model"])' | python - $config
    Check ($LASTEXITCODE -eq 0 -and $parsed[0] -eq 'vendor_b' -and $parsed[1] -eq 'model-c') 'independent TOML parser validates generated configuration'
    Write-Output ('PASS '+$script:Pass+'; root='+$root)
}finally{if(!$KeepTemp -and [IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath($env:TEMP),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $root -Recurse -Force}}
