# Provider profiles: UTF-8; credentials are protected by current-user Windows DPAPI.
function Get-ProfileStore([string]$ConfigPath) {
    $dir = Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ConfigPath))) 'codex-switcher'
    $path = Join-Path $dir 'providers.json'
    if ([IO.File]::Exists($path)) {
        $store = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        if ($store.version -ne 1) { throw 'Unsupported provider store version.' }
        return $store
    }
    $state = Read-State $dir
    $profiles = @()
    $keyPath = Join-Path $dir 'deepseek.key'
    if ($state -and $state.apiBase -and [IO.File]::Exists($keyPath)) {
        $models = @(Split-ModelList ([string]$state.model))
        if ($state.catalog -and [IO.File]::Exists([string]$state.catalog)) {
            foreach ($slug in @(Get-CatalogSlugs (Read-CatalogObject $state.catalog))) { if ($models -notcontains $slug) { $models += $slug } }
        }
        $profiles += [pscustomobject]@{ id='deepseek'; name='DeepSeek'; baseUrl=[string]$state.apiBase; models=$models; catalog=[string]$state.catalog; credential=[IO.File]::ReadAllText($keyPath); succeeded=$true }
    }
    $text = [IO.File]::ReadAllText($ConfigPath)
    $clean = [regex]::Replace($text,'(?ms)^# CODEX-SWITCHER-BEGIN\r?\n.*?^# CODEX-SWITCHER-END\r?\n?','')
    $split = Split-Config $clean
    $provider = Root-Value $split.Root 'model_provider'
    $official = if ($state) { @($state.officialRoot) } elseif (!$provider -or $provider -eq 'openai') { @($split.Root) } else { $null }
    return [pscustomobject]@{ version=1; selected=$(if($state -and $state.mode -eq 'deepseek'){'deepseek'}else{'openai'}); officialRoot=$official; officialCaptured=([bool]$state -or !$provider -or $provider -eq 'openai'); profiles=@($profiles) }
}
function Save-ProfileStore([string]$ConfigPath,$Store) {
    $path = Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ConfigPath))) 'codex-switcher\providers.json'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
    Atomic-Write $path ($Store | ConvertTo-Json -Depth 30)
}
function New-ProviderProfile([string]$Id,[string]$Name,[string]$BaseUrl,[string]$Models,[string]$Key,[string]$Catalog,$Previous) {
    if ($Id -notmatch '^[a-z][a-z0-9_-]{0,63}$' -or $Id -in @('openai','codex_switcher_deepseek')) { throw '供应商 ID 需为小写英文字母开头，只能包含字母、数字、下划线、短横线；openai 为保留名称。' }
    if (!$Name.Trim()) { throw '请填写供应商名称。' }
    $uri=$null
    if (![uri]::TryCreate($BaseUrl,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw '接口地址必须是 HTTPS 基础地址，不含密码、查询参数或片段。' }
    $list=@(Split-ModelList $Models)
    if (!$list.Count) { throw '请填写至少一个模型，第一个模型将作为默认模型。' }
    foreach($model in $list) { if($model -notmatch '^[A-Za-z0-9_./:-]+$'){throw '模型名称格式无效。'} }
    if ($Catalog) {
        $Catalog=[IO.Path]::GetFullPath($Catalog)
        $object=Read-CatalogObject $Catalog
        foreach($model in $list) {
            $entry=@($object.models | Where-Object {$_.slug -eq $model}) | Select-Object -First 1
            if (!$entry) { throw ('模型目录缺少模型：'+$model) }
            if (!(Test-CatalogEntryComplete $entry)) { throw ('模型目录缺少 base_instructions：'+$model) }
        }
    }
    $credential=if($Previous){[string]$Previous.credential}else{''}
    if ($Key) { if($Key -match '\s'){throw '密钥不能含空白字符。'}; $credential=ConvertFrom-SecureString (ConvertTo-SecureString $Key -AsPlainText -Force) }
    if (!$credential) { throw '首次添加供应商请填写 API Key。' }
    return [pscustomobject]@{ id=$Id; name=$Name.Trim(); baseUrl=$BaseUrl.TrimEnd('/'); models=$list; catalog=$Catalog; credential=$credential; succeeded=$false }
}
function Set-ProviderProfile($Store,$Profile) {
    $Store.profiles=@(@($Store.profiles) | Where-Object { $_.id -ne $Profile.id }) + @($Profile)
}
function Get-ProfileDefinitions([string]$Dir,$Profiles) {
    $lines=New-Object 'Collections.Generic.List[string]'
    $lines.Add('# CODEX-PROFILES-BEGIN')
    foreach($profile in @($Profiles)) {
        $id=[string]$profile.id
        if($id -notmatch '^[a-z][a-z0-9_-]{0,63}$' -or $id -eq 'openai'){throw 'Invalid stored provider ID.'}
        $lines.Add('[model_providers.'+$id+']')
        $lines.Add('name = '+(Quote-Toml ([string]$profile.name)))
        $lines.Add('base_url = '+(Quote-Toml ([string]$profile.baseUrl)))
        $lines.Add('wire_api = "responses"')
        $lines.Add('[model_providers.'+$id+'.auth]')
        $lines.Add('command = '+(Quote-Toml (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')))
        $lines.Add('args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", '+(Quote-Toml (Join-Path $Dir 'profile-credential.ps1'))+', "-EmitKey", "-KeyFile", '+(Quote-Toml (Join-Path $Dir ('keys\'+$id+'.key')))+']')
        $lines.Add('timeout_ms = 10000')
        $lines.Add('refresh_interval_ms = 0')
    }
    $lines.Add('# CODEX-PROFILES-END')
    return ($lines -join "`r`n")
}
function Switch-ProviderProfile([string]$ConfigPath,$Store,[string]$Id,[switch]$MigrateChats,[string]$OfficialModel) {
    $ConfigPath=[IO.Path]::GetFullPath($ConfigPath)
    $dir=Join-Path ([IO.Path]::GetDirectoryName($ConfigPath)) 'codex-switcher'
    $script:DiagnosticLog=Join-Path $dir 'runtime.log'
    $migration=$null; $backups=@(); $started=$false
    try {
        Write-Diagnostic INFO ('Profile switch requested: '+$Id+'; migrate='+$MigrateChats)
        Assert-Closed
        $original=[IO.File]::ReadAllText($ConfigPath)
        $clean=[regex]::Replace($original,'(?ms)^# CODEX-PROFILES-BEGIN\r?\n.*?^# CODEX-PROFILES-END\r?\n?','')
        $split=Split-Config $clean
        $current=Root-Value $split.Root 'model_provider'
        if (!$current -or $current -eq 'openai') { $Store.officialRoot=@($split.Root); $Store.officialCaptured=$true }
        if ($original -match '(?m)^\s*profile\s*=') { throw '检测到 profile 选择器，请先移除或迁移它。' }
        $targetModel=''; $effort='high'; $profile=$null
        if($Id -eq 'openai') {
            if(!$Store.officialCaptured) { throw '没有保存的官方配置。请先恢复官方配置后再导入。' }
            $roots=@($Store.officialRoot)
            $targetModel=Root-Value $roots 'model'
            if(!$targetModel){$targetModel=$OfficialModel}
            if(!$targetModel){$targetModel=Resolve-OfficialModel ([IO.Path]::GetDirectoryName($ConfigPath))}
            if($MigrateChats -and !$targetModel){throw '迁移历史会话需明确的官方模型；可关闭历史迁移或在模型栏填写官方模型名。'}
            if($MigrateChats -and $targetModel -notmatch '^gpt-'){throw '官方目标模型应为明确的 gpt-* 模型。'}
            $effort=Root-Value $roots 'model_reasoning_effort'; if(!$effort){$effort='medium'}
        } else {
            $profile=@($Store.profiles | Where-Object {$_.id -eq $Id}) | Select-Object -First 1
            if(!$profile){throw '找不到所选供应商。'}
            if($profile.catalog -and ![IO.File]::Exists($profile.catalog)){
                $cached=Join-Path $dir ('catalogs\'+$profile.id+'.json')
                if([IO.File]::Exists($cached)){$profile.catalog=$cached}
            }
            $profile=New-ProviderProfile $profile.id $profile.name $profile.baseUrl ($profile.models -join ',') '' $profile.catalog $profile
            Set-ProviderProfile $Store $profile
            $targetModel=$profile.models[0]
            $roots=@(('model_provider = '+(Quote-Toml $Id)),('model = '+(Quote-Toml $targetModel)),'model_reasoning_effort = "high"','web_search = "disabled"')
            if($profile.catalog){
                $roots+='model_catalog_json = '+(Quote-Toml (Join-Path $dir ('catalogs\'+$Id+'.json')))
                $metadata=@((Read-CatalogObject $profile.catalog).models | Where-Object {$_.slug -eq $targetModel}) | Select-Object -First 1
                if($metadata.supports_reasoning_summaries -eq $true){$roots+='model_supports_reasoning_summaries = true';$roots+='model_reasoning_summary = "none"'}
                $window=0L
                if([long]::TryParse([string]$metadata.context_window,[ref]$window) -and $window -gt 0){$roots+='model_context_window = '+$window}
            }
        }
        # Keep the old bounded definitions as compatibility aliases for existing threads.
        $legacyDeepseek=$original -match '(?m)^# CODEX-SWITCHER-BEGIN'
        $profilesToWrite=@($Store.profiles | Where-Object { !($legacyDeepseek -and $_.id -eq 'deepseek') })
        foreach($p in $profilesToWrite){if($clean -match ('(?m)^\s*\[model_providers\.["'']?'+[regex]::Escape($p.id)+'["'']?\]')){throw ('配置已有同名供应商，避免覆盖请换一个 ID：'+$p.id)}}
        # When editing imported DeepSeek, replace its old managed block and retain the alias.
        if($legacyDeepseek -and @($Store.profiles | Where-Object {$_.id -eq 'deepseek'}).Count){
            $clean=[regex]::Replace($clean,'(?ms)^# CODEX-SWITCHER-BEGIN\r?\n.*?^# CODEX-SWITCHER-END\r?\n?','')
            $profilesToWrite=@($Store.profiles)
        }
        $definitions=Get-ProfileDefinitions $dir $profilesToWrite
        if($legacyDeepseek -and @($Store.profiles | Where-Object {$_.id -eq 'deepseek'}).Count){
            $alias=Get-ProfileDefinitions $dir @($Store.profiles | Where-Object {$_.id -eq 'deepseek'})
            $alias=$alias.Replace('model_providers.deepseek','model_providers.codex_switcher_deepseek').Replace('# CODEX-PROFILES-BEGIN','').Replace('# CODEX-PROFILES-END','')
            $definitions=$definitions.Replace('# CODEX-PROFILES-END',$alias+"`r`n# CODEX-PROFILES-END")
        } elseif($original -match 'model_providers.codex_switcher_deepseek' -and @($Store.profiles | Where-Object {$_.id -eq 'deepseek'}).Count){
            $alias=Get-ProfileDefinitions $dir @($Store.profiles | Where-Object {$_.id -eq 'deepseek'})
            $alias=$alias.Replace('model_providers.deepseek','model_providers.codex_switcher_deepseek').Replace('# CODEX-PROFILES-BEGIN','').Replace('# CODEX-PROFILES-END','')
            $definitions=$definitions.Replace('# CODEX-PROFILES-END',$alias+"`r`n# CODEX-PROFILES-END")
        }
        $updated=Make-Config $clean $roots ($definitions+"`r`n")
        if(@(Get-DuplicateRootKeys $updated).Count){throw '生成配置出现重复根键，已取消。'}
        $backupRoot=Join-Path $dir ('profile-backups\'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($backupRoot)|Out-Null
        $paths=@($ConfigPath,(Join-Path $dir 'providers.json'),(Join-Path $dir 'profile-credential.ps1'))
        foreach($p in @($Store.profiles)){
            $paths+=Join-Path $dir ('keys\'+$p.id+'.key')
            if($p.catalog){$paths+=Join-Path $dir ('catalogs\'+$p.id+'.json')}
        }
        foreach($path in $paths){
            $exists=[IO.File]::Exists($path);$backup=Join-Path $backupRoot ('file-'+$backups.Count)
            if($exists){Copy-Item -LiteralPath $path -Destination $backup}
            $backups+=[pscustomobject]@{path=$path;backup=$backup;existed=$exists}
        }
        Atomic-Write (Join-Path $backupRoot 'files.json') ($backups|ConvertTo-Json -Depth 5)
        if($original -cne [IO.File]::ReadAllText($ConfigPath)){throw '配置已被其它程序修改，请重试。'}
        Assert-Closed; $started=$true
        Copy-Item -LiteralPath $script:SourceScript -Destination (Join-Path $dir 'profile-credential.ps1') -Force
        foreach($p in @($Store.profiles)){
            [IO.Directory]::CreateDirectory((Join-Path $dir 'keys'))|Out-Null
            Atomic-Write (Join-Path $dir ('keys\'+$p.id+'.key')) $p.credential
            if($p.catalog){
                $activeCatalog=Join-Path $dir ('catalogs\'+$p.id+'.json')
                if([IO.File]::Exists($p.catalog)){
                    [IO.Directory]::CreateDirectory((Join-Path $dir 'catalogs'))|Out-Null
                    Atomic-Write $activeCatalog ([IO.File]::ReadAllText($p.catalog))
                } elseif(![IO.File]::Exists($activeCatalog)){throw ('找不到模型目录：'+$p.id)}
            }
        }
        if($MigrateChats){$migration=Migrate-AllChats ([IO.Path]::GetDirectoryName($ConfigPath)) $Id $targetModel $effort (Join-Path $backupRoot 'chats')}
        Assert-Closed
        $Store.selected=$Id
        if($profile){$profile.succeeded=$true}
        Save-ProfileStore $ConfigPath $Store
        Atomic-Write $ConfigPath $updated
        Write-Diagnostic INFO ('Profile switch succeeded: '+$Id+'; backup='+$backupRoot)
        return ('切换成功：'+$Id+' / '+$targetModel+"`r`n供应商档案已保存。请重启 Codex。`r`n备份："+$backupRoot+"`r`n历史会话迁移："+$MigrateChats)
    } catch {
        $failure=$_
        if($started){
            try{Restore-ChatMigration $migration}catch{Write-Diagnostic ERROR ('Chat rollback failed: '+$_.Exception.Message)}
            foreach($b in $backups){try{if($b.existed){Copy-Item -LiteralPath $b.backup -Destination $b.path -Force}elseif([IO.File]::Exists($b.path)){[IO.File]::Delete($b.path)}}catch{Write-Diagnostic ERROR ('File rollback failed: '+$b.path+'; '+$_.Exception.Message)}}
        }
        Write-Diagnostic ERROR ($failure.Exception.ToString()+"`n"+$failure.ScriptStackTrace)
        throw $failure
    }
}
