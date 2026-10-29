param([switch]$EmitKey, [string]$KeyFile, [switch]$LibraryOnly, [switch]$UiSmoke)
$ErrorActionPreference = 'Stop'
if ($EmitKey) {
    try {
        $secure = ConvertTo-SecureString ([IO.File]::ReadAllText($KeyFile))
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { [Console]::Write([Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
        exit 0
    } catch { [Console]::Error.WriteLine('Unable to unlock provider credential. Re-enter the key in Switcher.'); exit 1 }
}
$script:SourceScript = $PSCommandPath
$script:DiagnosticLog = Join-Path $env:LOCALAPPDATA 'Codex-Switcher\logs\runtime.log'
$script:ManagedKeys = @('model','model_provider','model_catalog_json','model_context_window','model_auto_compact_token_limit','model_reasoning_effort','model_reasoning_summary','model_verbosity','model_supports_reasoning_summaries','disable_response_storage','forced_login_method','openai_base_url','review_model','service_tier')
$script:Utf8 = New-Object Text.UTF8Encoding($false)

function Quote-Toml([string]$Value) {
    if ($Value -match '[\x00-\x1f]') { throw '配置值不能包含换行或控制字符。' }
    return '"' + $Value.Replace('\','\\').Replace('"','\"') + '"'
}
function Split-Config([string]$Text) {
    # Deliberately refuses multiline strings rather than risking unrelated TOML content.
    if ($Text.Contains('"""') -or $Text.Contains("'''")) { throw '此配置含 TOML 多行字符串，工具无法安全局部编辑，未做修改。' }
    $lines = [regex]::Split($Text, '\r?\n')
    $roots = New-Object 'Collections.Generic.List[string]'
    $keep = New-Object 'Collections.Generic.List[string]'
    $atRoot = $true
    foreach ($line in $lines) {
        if ($line -match '^\s*\[') { $atRoot = $false }
        if ($atRoot -and $line -match '^\s*["'']?([A-Za-z_][\w-]*)["'']?\s*=') {
            if ($script:ManagedKeys -contains $Matches[1]) { $roots.Add($line); continue }
        }
        $keep.Add($line)
    }
    return @{ Root = @($roots.ToArray()); Rest = ($keep.ToArray() -join "`r`n") }
}
function Root-Value($Lines, [string]$Name) {
    foreach ($line in $Lines) {
        if ($line -match ('^\s*["'']?' + [regex]::Escape($Name) + '["'']?\s*=\s*["'']([^"'']*)["'']')) { return $Matches[1] }
    }
    return $null
}
function Get-DuplicateRootKeys([string]$Text) {
    # 同一个顶层键出现两次会让 Codex 直接启动失败，所以写入前先自检。
    $seen = @{}
    $duplicates = New-Object 'Collections.Generic.List[string]'
    foreach ($line in [regex]::Split([string]$Text,'\r?\n')) {
        if ($line -match '^\s*\[') { break }
        $match = [regex]::Match($line,'^\s*["'']?([A-Za-z_][\w-]*)["'']?\s*=')
        if (!$match.Success) { continue }
        $name = $match.Groups[1].Value
        if ($seen.ContainsKey($name)) { if (!$duplicates.Contains($name)) { $duplicates.Add($name) } }
        else { $seen[$name] = $true }
    }
    return @($duplicates.ToArray())
}
function Get-OfficialCatalogModels([string]$CodexRoot) {
    # Codex 在官方登录下会把服务器下发的模型目录缓存到 models_cache.json。
    $path = Join-Path $CodexRoot 'models_cache.json'
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    try { $object = ([IO.File]::ReadAllText($path) | ConvertFrom-Json) } catch { return @() }
    $list = New-Object 'Collections.Generic.List[object]'
    foreach ($model in @($object.models)) {
        $slug = [string]$model.slug
        if (!$slug) { continue }
        $priority = 999
        $value = 0
        if ($model.PSObject.Properties['priority'] -and [int]::TryParse([string]$model.priority,[ref]$value)) { $priority = $value }
        $hidden = $false
        if ($model.PSObject.Properties['visibility'] -and [string]$model.visibility -eq 'hide') { $hidden = $true }
        $list.Add([pscustomobject]@{ Slug=$slug; Priority=$priority; Hidden=$hidden })
    }
    return @($list.ToArray())
}
function Get-OfficialModelWhitelist([string]$CodexRoot) {
    # 桌面应用在官方登录下写入的可用模型清单；只读，读不到就当没有。
    $path = Join-Path $CodexRoot '.codex-global-state.json'
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    try {
        $text = [IO.File]::ReadAllText($path)
        $match = [regex]::Match($text,'"eligible_codex_model_slugs"\s*:\s*(\[[^\]]*\])')
        if (!$match.Success) { return @() }
        # 注意：Windows PowerShell 5.1 里不能写成 `$text | ConvertFrom-Json`，
        # 那样整段 JSON 数组会被当成一个字符串（用空格拼起来），这里显式解析再逐项取出。
        $items = ConvertFrom-Json -InputObject $match.Groups[1].Value
        $list = New-Object 'Collections.Generic.List[string]'
        if ($items -is [string]) { if ($items) { $list.Add([string]$items) } }
        else { foreach ($item in @($items)) { if ($item) { $list.Add([string]$item) } } }
        return @($list.ToArray())
    } catch { return @() }
}
function Get-DeepSeekCatalogSlugs([string]$CodexRoot) {
    # 工具自己写到 codex-switcher\deepseek-models.json 的第三方模型清单：这些名字一律不当官方模型用。
    $path = Join-Path (Join-Path $CodexRoot 'codex-switcher') 'deepseek-models.json'
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    try {
        $text = [IO.File]::ReadAllText($path)
        if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
        $list = New-Object 'Collections.Generic.List[string]'
        foreach ($match in [regex]::Matches($text,'"slug"\s*:\s*"([^"]+)"')) { $list.Add($match.Groups[1].Value) }
        return @($list.ToArray())
    } catch { return @() }
}
function Get-OfficialModelCandidates([string]$CodexRoot) {
    # 候选顺序：应用记录的默认模型（去掉 -wm 后缀）-> 官方目录里优先级最高的可见模型。
    $list = New-Object 'Collections.Generic.List[string]'
    $statePath = Join-Path $CodexRoot '.codex-global-state.json'
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try {
            $text = [IO.File]::ReadAllText($statePath)
            foreach ($match in [regex]::Matches($text,'"default_model_slug"\s*:\s*"([^"]+)"')) {
                $slug = $match.Groups[1].Value
                if ($slug.EndsWith('-wm',[StringComparison]::Ordinal)) { $slug = $slug.Substring(0,$slug.Length - 3) }
                if ($slug -and !$list.Contains($slug)) { $list.Add($slug) }
            }
        } catch { }
    }
    foreach ($slug in @(Get-OfficialModelWhitelist $CodexRoot)) { if (!$list.Contains($slug)) { $list.Add($slug) } }
    $models = @(Get-OfficialCatalogModels $CodexRoot | Where-Object { !$_.Hidden } | Sort-Object Priority)
    foreach ($model in $models) { if (!$list.Contains($model.Slug)) { $list.Add($model.Slug) } }
    return @($list.ToArray())
}
function Test-OfficialModelKnown([string]$CodexRoot) {
    # 本机是否留下过任何官方模型线索：用来区分“确认不是官方模型”和“无从判断”。
    return [bool](@(Get-OfficialModelCandidates $CodexRoot).Count -gt 0)
}
function Test-OfficialModelName([string]$CodexRoot,[string]$Name) {
    # 只有拿到官方证据（应用清单或官方目录缓存）才认可一个名字，避免把第三方模型当成官方模型。
    if (!$Name) { return $false }
    if (@(Get-DeepSeekCatalogSlugs $CodexRoot) -contains $Name) { return $false }
    $whitelist = @(Get-OfficialModelWhitelist $CodexRoot)
    if ($whitelist.Count -gt 0) { return [bool]($whitelist -contains $Name) }
    $models = @(Get-OfficialCatalogModels $CodexRoot)
    if ($models.Count -eq 0) { return $false }
    return [bool](@($models | Where-Object { $_.Slug -eq $Name }).Count -gt 0)
}
function Resolve-OfficialModel([string]$CodexRoot) {
    foreach ($candidate in @(Get-OfficialModelCandidates $CodexRoot)) {
        if (Test-OfficialModelName $CodexRoot $candidate) { return $candidate }
    }
    return ''
}
function Make-Config([string]$Original, [string[]]$Root, [string]$Extra = '') {
    $split = Split-Config $Original
    # 目标根键为空时要退化成“官方配置本来就没写这些键”，不能留一个空行。
    $head = if (@($Root).Count -gt 0) { ($Root -join "`r`n") + "`r`n" } else { '' }
    return ($head + $split.Rest.TrimEnd() + "`r`n" + $Extra)
}
function Atomic-Write([string]$Path, [string]$Text) {
    $tmp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($tmp, $Text, $script:Utf8)
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($tmp, $Path) }
    } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
}
function Read-State([string]$Dir) {
    $p = Join-Path $Dir 'state.json'
    if (Test-Path -LiteralPath $p) { return ([IO.File]::ReadAllText($p) | ConvertFrom-Json) }
    return $null
}
function Split-ModelList([string]$Value) {
    # 模型名可以自由填写；多个用逗号、分号或空白分隔，第一个为当前生效模型。
    $items = New-Object 'Collections.Generic.List[string]'
    foreach ($piece in [regex]::Split([string]$Value,'[,;\s]+')) {
        $name = $piece.Trim()
        if ($name -and !$items.Contains($name)) { $items.Add($name) }
    }
    return @($items.ToArray())
}
function Read-CatalogObject([string]$Path) {
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw ('找不到模型目录文件：' + $Path) }
    $object = $null
    $text = [IO.File]::ReadAllText($Path)
    if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
    try { $object = ($text | ConvertFrom-Json) }
    catch { throw ('模型目录不是有效 JSON：' + $Path + '；' + $_.Exception.Message) }
    if (!$object -or !$object.PSObject.Properties['models'] -or @($object.models).Count -eq 0) {
        throw ('模型目录没有 models 数组或内容为空：' + $Path)
    }
    return $object
}
function Get-CatalogSlugs($CatalogObject) {
    $list = New-Object 'Collections.Generic.List[string]'
    foreach ($entry in @($CatalogObject.models)) { if ($entry.slug) { $list.Add([string]$entry.slug) } }
    return @($list.ToArray())
}
function Set-ObjectProperty($Object,[string]$Name,$Value) {
    if ($Object.PSObject.Properties[$Name]) { $Object.PSObject.Properties[$Name].Value = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}
function New-CatalogEntry($Template,[string]$Slug,[int]$Priority) {
    $entry = if ($Template) { ($Template | ConvertTo-Json -Depth 25 | ConvertFrom-Json) } else { New-Object psobject }
    Set-ObjectProperty $entry 'slug' $Slug
    Set-ObjectProperty $entry 'display_name' $Slug
    Set-ObjectProperty $entry 'description' '由 Codex 切换工具按你填写的模型名添加；能力元数据继承自目录中的模板条目。'
    Set-ObjectProperty $entry 'priority' $Priority
    return $entry
}
function Test-CatalogEntryComplete($Entry) {
    # Codex 会校验能力元数据；缺少 base_instructions 的条目会让它启动失败。
    return [bool]($Entry -and $Entry.PSObject.Properties['base_instructions'])
}
function Get-CompleteCatalogEntry($CatalogObject) {
    foreach ($entry in @($CatalogObject.models)) { if (Test-CatalogEntryComplete $entry) { return $entry } }
    return $null
}
function Get-CatalogDerivationTemplate($CatalogObject) {
    # 优先用目录里已有的完整条目；目录条目不完整时退回工具自带的完整条目。
    $complete = Get-CompleteCatalogEntry $CatalogObject
    if ($complete) { return $complete }
    $bundled = Join-Path ([IO.Path]::GetDirectoryName($script:SourceScript)) 'deepseek-models.json'
    if (Test-Path -LiteralPath $bundled -PathType Leaf) {
        try { $complete = Get-CompleteCatalogEntry (Read-CatalogObject $bundled) } catch { $complete = $null }
        if ($complete) { return $complete }
    }
    return @($CatalogObject.models)[0]
}
function Add-CatalogModels($CatalogObject,[string[]]$Models) {
    # 只追加目录里没有的模型；已存在的不动，避免重复条目。
    $existing = @(Get-CatalogSlugs $CatalogObject)
    $template = Get-CatalogDerivationTemplate $CatalogObject
    $priority = 0
    foreach ($entry in @($CatalogObject.models)) {
        $value = 0
        if ($entry.PSObject.Properties['priority'] -and [int]::TryParse([string]$entry.priority,[ref]$value)) {
            if ($value -gt $priority) { $priority = $value }
        }
    }
    $added = New-Object 'Collections.Generic.List[string]'
    foreach ($slug in @($Models)) {
        if ($existing -contains $slug) { continue }
        $priority++
        $CatalogObject.models = @($CatalogObject.models) + (New-CatalogEntry $template $slug $priority)
        $added.Add($slug)
        $existing += $slug
    }
    return @($added.ToArray())
}
function Backup-CatalogFile([string]$Path,[string]$Dir) {
    try {
        $target = Join-Path (Join-Path $Dir 'catalog-backups') ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [IO.Path]::GetFileName($Path))
        $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force
        Copy-Item -LiteralPath $Path -Destination $target -Force
        return $target
    } catch { return $null }
}
function Convert-ToLfText([string]$Text) {
    # 仓库与 JSON 统一 LF，避免行尾在版本管理里反复变动。
    return ([string]$Text -replace "`r`n","`n")
}
function Resolve-DefaultCatalog([string]$DefaultHome,[string]$ScriptRoot) {
    # 优先沿用上次使用过的目录，其次本机既有 models.json，最后用工具自带目录。
    foreach ($candidate in @((Join-Path $DefaultHome 'models.json'),(Join-Path $ScriptRoot 'deepseek-models.json'))) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    return ''
}
function Assert-Closed {
    $active = @(Get-Process -Name 'Codex','ChatGPT' -ErrorAction SilentlyContinue)
    if ($active.Count -gt 0) { throw '请先正常退出 Codex / ChatGPT 桌面应用及 Codex 命令行，再点击切换。工具不会强制结束正在运行的任务。' }
}
function Write-Log([string]$Dir,[string]$Message) {
    [IO.File]::AppendAllText((Join-Path $Dir 'switch.log'), ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Message) + "`r`n", $script:Utf8)
}
$script:ProgressHandler = $null
$script:TimingRows = $null
function Report-Progress([int]$Percent,[string]$Message) {
    Write-Diagnostic 'INFO' ('Progress ' + $Percent + '%: ' + $Message)
    if ($script:ProgressHandler) {
        try { & $script:ProgressHandler $Percent $Message } catch { }
    }
}
function Add-SwitchTiming([string]$Phase,[double]$Ms,[string]$Note = '') {
    if ($null -eq $script:TimingRows) { $script:TimingRows = New-Object 'Collections.Generic.List[object]' }
    $script:TimingRows.Add([pscustomobject]@{ Phase=$Phase; Ms=[Math]::Round($Ms,1); Note=$Note })
}
function Format-SwitchTiming {
    if (!$script:TimingRows -or $script:TimingRows.Count -eq 0) { return '' }
    $lines = New-Object 'Collections.Generic.List[string]'
    foreach ($row in $script:TimingRows) {
        $line = '  ' + (([double]$row.Ms).ToString('N1')).PadLeft(9) + ' ms  ' + $row.Phase
        if ($row.Note) { $line += '  ' + $row.Note }
        $lines.Add($line)
    }
    return ($lines.ToArray() -join "`r`n")
}
function Get-SwitchTimingTotalMs {
    if (!$script:TimingRows) { return 0 }
    $total = 0.0
    foreach ($row in $script:TimingRows) { $total += [double]$row.Ms }
    return $total
}
function Initialize-SqliteInterop {
    if ('CodexSwitcherSqlite' -as [type]) { return }
    $source = Join-Path ([IO.Path]::GetDirectoryName($script:SourceScript)) 'ChatMigration.cs'
    if (!(Test-Path -LiteralPath $source -PathType Leaf)) { throw "缺少会话迁移组件：$source" }
    Add-Type -Path $source
}
function Find-CodexStateDatabase([string]$CodexRoot) {
    Initialize-SqliteInterop
    $candidates = @(
        Get-ChildItem -LiteralPath $CodexRoot -Filter 'state_*.sqlite' -File -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath (Join-Path $CodexRoot 'sqlite') -Filter 'state_*.sqlite' -File -ErrorAction SilentlyContinue
    ) | Sort-Object LastWriteTime -Descending
    foreach ($candidate in $candidates) {
        if ([CodexSwitcherSqlite]::HasThreadsTable($candidate.FullName)) { return $candidate.FullName }
    }
    return $null
}
function Find-CodexProjectionDatabase([string]$CodexRoot) {
    Initialize-SqliteInterop
    $candidates = @(
        Get-ChildItem -LiteralPath $CodexRoot -Filter 'thread_history_*.sqlite' -File -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath (Join-Path $CodexRoot 'sqlite') -Filter 'thread_history_*.sqlite' -File -ErrorAction SilentlyContinue
    ) | Sort-Object LastWriteTime -Descending
    foreach ($candidate in $candidates) {
        if ([CodexSwitcherSqlite]::HasProjectionTables($candidate.FullName)) { return $candidate.FullName }
    }
    return $null
}
function Get-RolloutFiles([string]$CodexRoot) {
    $result = New-Object 'Collections.Generic.List[IO.FileInfo]'
    foreach ($name in @('sessions','archived_sessions')) {
        $root = Join-Path $CodexRoot $name
        if (Test-Path -LiteralPath $root -PathType Container) {
            foreach ($file in Get-ChildItem -LiteralPath $root -Filter 'rollout-*.jsonl' -File -Recurse -ErrorAction Stop) {
                $result.Add($file)
            }
        }
    }
    return @($result.ToArray())
}
function Set-ExistingJsonValue($Object,[string]$Name,$Value,$Stats,[string]$Counter='RouteChanges') {
    if ($null -eq $Object) { return }
    $property = $Object.PSObject.Properties[$Name]
    if ($property -and $property.Value -ne $Value) {
        $property.Value = $Value
        $Stats[$Counter]++
    }
}
function Remove-JsonProperty($Object,[string]$Name,$Stats) {
    if ($null -eq $Object) { return }
    if ($Object.PSObject.Properties[$Name]) {
        $Object.PSObject.Properties.Remove($Name)
        $Stats.CompatibilityChanges++
    }
}
function Convert-ToolIdentifier([string]$Value,$Stats,$Map) {
    if (!$Value -or !$Value.StartsWith('tool_',[StringComparison]::Ordinal)) { return $Value }
    if (!$Map.ContainsKey($Value)) { $Map[$Value] = 'fc_' + $Value.Substring(5) }
    $Stats.CompatibilityChanges++
    return $Map[$Value]
}
function Convert-CompatibleHistoryNode($Node,[string]$Provider,$Stats,$ToolIds) {
    if ($null -eq $Node -or $Node -is [string] -or $Node.GetType().IsPrimitive) { return }
    if ($Node -is [Collections.IEnumerable] -and !($Node -is [Management.Automation.PSCustomObject]) -and !($Node -is [Collections.IDictionary])) {
        foreach ($item in $Node) { Convert-CompatibleHistoryNode $item $Provider $Stats $ToolIds }
        return
    }
    $typeProperty = $Node.PSObject.Properties['type']
    $itemType = if ($typeProperty) { [string]$typeProperty.Value } else { '' }
    if ($itemType -eq 'reasoning') {
        Remove-JsonProperty $Node 'encrypted_content' $Stats
        Remove-JsonProperty $Node 'id' $Stats
        if ($Provider -eq 'openai' -and $Node.PSObject.Properties['content'] -and @($Node.content).Count -gt 0) {
            $Node.content = @()
            $Stats.CompatibilityChanges++
        }
    }
    if ($itemType -in @('function_call','function_call_output','custom_tool_call','custom_tool_call_output','tool_search_call','tool_search_output')) {
        foreach ($name in @('call_id','id')) {
            $property = $Node.PSObject.Properties[$name]
            if ($property -and $property.Value -is [string] -and $property.Value.StartsWith('tool_',[StringComparison]::Ordinal)) {
                $property.Value = Convert-ToolIdentifier ([string]$property.Value) $Stats $ToolIds
            }
        }
    }
    foreach ($property in @($Node.PSObject.Properties)) {
        Convert-CompatibleHistoryNode $property.Value $Provider $Stats $ToolIds
    }
}
function Set-RolloutRuntimeFields($Record,[string]$Provider,[string]$Model,[string]$Effort,$Stats) {
    $payload = $Record.payload
    if (!$payload) { return }
    switch ([string]$Record.type) {
        'session_meta' {
            Set-ExistingJsonValue $payload 'model_provider' $Provider $Stats
        }
        'turn_context' {
            Set-ExistingJsonValue $payload 'model' $Model $Stats
            Set-ExistingJsonValue $payload 'effort' $Effort $Stats
            if ($payload.collaboration_mode -and $payload.collaboration_mode.settings) {
                Set-ExistingJsonValue $payload.collaboration_mode.settings 'model' $Model $Stats
                Set-ExistingJsonValue $payload.collaboration_mode.settings 'reasoning_effort' $Effort $Stats
            }
        }
        'event_msg' {
            if ($payload.type -eq 'thread_settings_applied' -and $payload.thread_settings) {
                Set-ExistingJsonValue $payload.thread_settings 'model' $Model $Stats
                Set-ExistingJsonValue $payload.thread_settings 'model_provider_id' $Provider $Stats
                Set-ExistingJsonValue $payload.thread_settings 'reasoning_effort' $Effort $Stats
                if ($Provider -ne 'openai') { Set-ExistingJsonValue $payload.thread_settings 'service_tier' $null $Stats }
                if ($payload.thread_settings.collaboration_mode -and $payload.thread_settings.collaboration_mode.settings) {
                    Set-ExistingJsonValue $payload.thread_settings.collaboration_mode.settings 'model' $Model $Stats
                    Set-ExistingJsonValue $payload.thread_settings.collaboration_mode.settings 'reasoning_effort' $Effort $Stats
                }
            }
        }
        'world_state' {
            if ($payload.state) {
                Set-ExistingJsonValue $payload.state 'model' $Model $Stats
                if ($payload.state.collaboration_mode) { Set-ExistingJsonValue $payload.state.collaboration_mode 'model' $Model $Stats }
                if ($payload.state.personality) { Set-ExistingJsonValue $payload.state.personality 'model' $Model $Stats }
            }
        }
        'compacted' {
            if ($payload.resume_metadata -and $payload.resume_metadata.previous_turn_settings) {
                Set-ExistingJsonValue $payload.resume_metadata.previous_turn_settings 'model' $Model $Stats
                Set-ExistingJsonValue $payload.resume_metadata.previous_turn_settings 'model_provider_id' $Provider $Stats
                Set-ExistingJsonValue $payload.resume_metadata.previous_turn_settings 'reasoning_effort' $Effort $Stats
            }
        }
    }
}
function Get-TextFileLayout([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $buffer = New-Object byte[] 65536
        $read = $stream.Read($buffer,0,$buffer.Length)
        $newline = "`n"
        for ($i=0; $i -lt $read; $i++) {
            if ($buffer[$i] -eq 10) { if ($i -gt 0 -and $buffer[$i-1] -eq 13) { $newline="`r`n" }; break }
        }
        $trailing = $false
        if ($stream.Length -gt 0) { $stream.Seek(-1,[IO.SeekOrigin]::End) | Out-Null; $trailing = ($stream.ReadByte() -eq 10) }
        return @{ Newline=$newline; Trailing=$trailing }
    } finally { $stream.Dispose() }
}
# 参考实现：仅供回归测试做等价性比对，生产路径是 ChatMigration.cs 里的 C# 引擎
# （语义相同，速度快两个数量级）。两者输出必须逐行等价，见 tests/Test-RolloutRewrite.ps1。
function Update-RolloutForTargetReference([string]$Path,[string]$Provider,[string]$Model,[string]$Effort) {
    $layout = Get-TextFileLayout $Path
    $stats = @{ RouteChanges=0; CompatibilityChanges=0 }
    $toolIds = @{}
    $tmp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $created = [IO.File]::GetCreationTimeUtc($Path)
    $written = [IO.File]::GetLastWriteTimeUtc($Path)
    $reader = $null; $writer = $null
    try {
        $reader = New-Object IO.StreamReader($Path,$script:Utf8,$true,65536)
        $writer = New-Object IO.StreamWriter($tmp,$false,$script:Utf8,65536)
        $first = $true
        $lineNumber = 0
        while (($line = $reader.ReadLine()) -ne $null) {
            $lineNumber++
            try { $record = $line | ConvertFrom-Json }
            catch { throw "会话文件第 $lineNumber 行不是有效 JSON：$Path" }
            if ($lineNumber -eq 1 -and ($record.type -ne 'session_meta' -or !$record.payload -or !$record.payload.PSObject.Properties['model_provider'])) {
                throw "会话文件缺少 session_meta.model_provider：$Path"
            }
            $before = $stats.RouteChanges + $stats.CompatibilityChanges
            Set-RolloutRuntimeFields $record $Provider $Model $Effort $stats
            Convert-CompatibleHistoryNode $record $Provider $stats $toolIds
            if ($first) { $first=$false } else { $writer.Write($layout.Newline) }
            if (($stats.RouteChanges + $stats.CompatibilityChanges) -ne $before) {
                $writer.Write(($record | ConvertTo-Json -Compress -Depth 100))
            } else { $writer.Write($line) }
        }
        if ($layout.Trailing -and !$first) { $writer.Write($layout.Newline) }
        $reader.Dispose(); $reader=$null; $writer.Dispose(); $writer=$null
        if (($stats.RouteChanges + $stats.CompatibilityChanges) -gt 0) {
            [IO.File]::Replace($tmp,$Path,[Management.Automation.Language.NullString]::Value)
            [IO.File]::SetCreationTimeUtc($Path,$created)
            [IO.File]::SetLastWriteTimeUtc($Path,$written)
        } else { [IO.File]::Delete($tmp) }
        return [pscustomobject]$stats
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($writer) { $writer.Dispose() }
        if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) }
    }
}
function Update-RolloutForTarget([string]$Path,[string]$Provider,[string]$Model,[string]$Effort,[switch]$Reference) {
    if ($Reference) { return Update-RolloutForTargetReference $Path $Provider $Model $Effort }
    Initialize-SqliteInterop
    $created = [IO.File]::GetCreationTimeUtc($Path)
    $written = [IO.File]::GetLastWriteTimeUtc($Path)
    $result = $null
    try {
        $result = [CodexSwitcherRollout]::RewriteFile($Path,$Provider,$Model,$Effort)
    } catch {
        $inner = $_.Exception
        if ($inner.InnerException) { $inner = $inner.InnerException }
        if ($inner -is [CodexSwitcherRolloutFormatException]) {
            throw ('会话文件第 ' + $inner.LineNumber + ' 行不是有效 JSON：' + $Path)
        }
        throw
    }
    try {
        if ($result.Changed) {
            [IO.File]::Replace($result.TempPath,$Path,[Management.Automation.Language.NullString]::Value)
            [IO.File]::SetCreationTimeUtc($Path,$created)
            [IO.File]::SetLastWriteTimeUtc($Path,$written)
        }
    } finally {
        if ($result.TempPath -and [IO.File]::Exists($result.TempPath)) { [IO.File]::Delete($result.TempPath) }
    }
    return [pscustomobject]@{
        RouteChanges=$result.RouteChanges
        CompatibilityChanges=$result.CompatibilityChanges
        Lines=$result.Lines
        ChangedLines=$result.ChangedLines
    }
}
function Get-TextPreview([string]$Text,[int]$Max = 160) {
    $clean = [regex]::Replace([string]$Text,'[\x00-\x1f]',' ')
    if ($clean.Length -gt $Max) { return ($clean.Substring(0,$Max) + '…') }
    return $clean
}
function Read-FirstLineUtf8([string]$Path) {
    # 会话文件是 UTF-8。Get-Content 在中文系统上会用 ANSI 代码页去读没有 BOM 的文件，
    # 首行里的中文/特殊字符会被读坏，所以这里显式按 UTF-8（自动识别 BOM）读取。
    $reader = New-Object IO.StreamReader($Path,(New-Object Text.UTF8Encoding($false)),$true)
    try { return $reader.ReadLine() } finally { $reader.Dispose() }
}
function Get-SessionHeader([string]$Path) {
    # 返回 @{ Header=…; Problem='' }。Problem 非空表示这个文件不能当会话文件用：
    # 调用方应当跳过它，而不是中止整次切换（损坏文件多半是一次异常退出留下的）。
    $result = @{ Header=$null; Problem='' }
    $size = -1
    try { $size = (New-Object IO.FileInfo($Path)).Length } catch { }
    if ($size -eq 0) { $result.Problem = '文件是空的（0 字节）'; return $result }
    $line = $null
    try { $line = [string](Read-FirstLineUtf8 $Path) } catch { $result.Problem = '读取失败：' + $_.Exception.Message; return $result }
    if ([string]::IsNullOrWhiteSpace($line)) { $result.Problem = '首行是空的（文件可能没写完）'; return $result }
    $header = $null
    try { $header = ($line | ConvertFrom-Json) }
    catch { $result.Problem = ('首行不是有效 JSON（首行 ' + $line.Length + ' 字符，开头：' + (Get-TextPreview $line) + '）'); return $result }
    if (!$header -or !$header.PSObject.Properties['payload'] -or !$header.payload) { $result.Problem = '首行不是 session_meta 记录（没有 payload）'; return $result }
    if ([string]$header.type -ne 'session_meta') { $result.Problem = ('首行不是 session_meta 记录（type=' + [string]$header.type + '）'); return $result }
    if (!$header.payload.PSObject.Properties['model_provider']) { $result.Problem = '首行缺少 session_meta.model_provider'; return $result }
    $result.Header = $header
    return $result
}
function Format-SkippedSessions($Skipped,[int]$Max = 10) {
    $items = @($Skipped)
    $lines = New-Object 'Collections.Generic.List[string]'
    $index = 0
    foreach ($item in $items) {
        $index++
        if ($index -gt $Max) { break }
        $lines.Add('  ' + $item.Path + ' —— ' + $item.Reason)
    }
    if ($items.Count -gt $Max) { $lines.Add('  …另有 ' + ($items.Count - $Max) + ' 个，见 switch.log') }
    return ($lines.ToArray() -join "`r`n")
}
function Get-RolloutHeader([string]$Path) {
    $session = Get-SessionHeader $Path
    if ($session.Problem) { throw ('会话文件不可用（' + $session.Problem + '）：' + $Path) }
    return $session.Header
}
function Find-RolloutOrdinalOffset([string]$Path,[long]$Ordinal) {
    Initialize-SqliteInterop
    $offset = [CodexSwitcherRollout]::FindOrdinalOffset($Path,$Ordinal)
    if ($offset -lt 0) { return $null }
    return $offset
}
function Set-HistoryBaseOffset([string]$Path,[long]$Offset) {
    $created = [IO.File]::GetCreationTimeUtc($Path)
    $written = [IO.File]::GetLastWriteTimeUtc($Path)
    $source = [IO.File]::OpenRead($Path)
    $bytes = New-Object 'Collections.Generic.List[byte]'
    try {
        while (($value=$source.ReadByte()) -ne -1) { if ($value -eq 10) { break }; $bytes.Add([byte]$value) }
        $hadNewline = ($value -eq 10)
        $firstBytes = $bytes.ToArray()
        $newline = if ($firstBytes.Length -gt 0 -and $firstBytes[$firstBytes.Length-1] -eq 13) { "`r`n" } else { "`n" }
        if ($newline -eq "`r`n") { $firstBytes = $firstBytes[0..($firstBytes.Length-2)] }
        $first = $script:Utf8.GetString($firstBytes)
        try { $header = $first | ConvertFrom-Json } catch { throw "分叉会话首行不是有效 JSON：$Path" }
        if (!$header.payload.history_base -or !$header.payload.history_base.PSObject.Properties['end_byte_offset']) {
            throw "分叉会话缺少 history_base.end_byte_offset：$Path"
        }
        $header.payload.history_base.end_byte_offset = $Offset
        $updated = $script:Utf8.GetBytes(($header | ConvertTo-Json -Compress -Depth 100))
        $tmp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        $destination = [IO.File]::Create($tmp)
        try {
            $destination.Write($updated,0,$updated.Length)
            if ($hadNewline) {
                $separator = $script:Utf8.GetBytes($newline)
                $destination.Write($separator,0,$separator.Length)
                $source.CopyTo($destination)
            }
        } finally { $destination.Dispose() }
    } finally { $source.Dispose() }
    try {
        [IO.File]::Replace($tmp,$Path,[Management.Automation.Language.NullString]::Value)
        [IO.File]::SetCreationTimeUtc($Path,$created)
        [IO.File]::SetLastWriteTimeUtc($Path,$written)
    } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
}
function Repair-ForkHistoryOffsets($RolloutEntries) {
    $byId = @{}
    $items = New-Object 'Collections.Generic.List[object]'
    foreach ($entry in @($RolloutEntries)) {
        $header = Get-RolloutHeader $entry.Original
        $id = [string]$header.payload.id
        $item = [pscustomobject]@{ Path=$entry.Original; Name=[IO.Path]::GetFileName($entry.Original); Id=$id; Header=$header }
        $items.Add($item)
        if ($id) {
            if (!$byId.ContainsKey($id)) { $byId[$id]=New-Object 'Collections.Generic.List[object]' }
            $byId[$id].Add($item)
        }
    }
    $fixed = 0
    foreach ($item in @($items.ToArray() | Sort-Object Name)) {
        $base = $item.Header.payload.history_base
        if (!$base -or !$base.PSObject.Properties['end_byte_offset'] -or !$base.PSObject.Properties['end_ordinal_exclusive']) { continue }
        $sourceId = [string]$base.thread_id
        if (!$byId.ContainsKey($sourceId)) { throw "分叉会话找不到源会话 $sourceId，已取消并恢复备份：$($item.Path)" }
        $candidates = @($byId[$sourceId].ToArray() | Where-Object { $_.Path -ne $item.Path } | Sort-Object Name -Descending)
        if ($candidates.Count -eq 0) { throw "分叉会话没有可用源文件 $sourceId，已取消并恢复备份：$($item.Path)" }
        $newOffset = $null
        foreach ($candidate in $candidates) {
            $newOffset = Find-RolloutOrdinalOffset $candidate.Path ([long]$base.end_ordinal_exclusive)
            if ($null -ne $newOffset) { break }
        }
        if ($null -eq $newOffset) { throw "无法重算分叉会话字节位置，已取消并恢复备份：$($item.Path)" }
        if ([long]$base.end_byte_offset -ne [long]$newOffset) {
            Set-HistoryBaseOffset $item.Path ([long]$newOffset)
            $fixed++
            $item.Header = Get-RolloutHeader $item.Path
        }
    }
    return $fixed
}
function Restore-ChatMigration($Migration) {
    if (!$Migration) { return }
    $errors = New-Object 'Collections.Generic.List[string]'
    if ($Migration.DatabasePath -and $Migration.DatabaseBackup -and (Test-Path -LiteralPath $Migration.DatabaseBackup)) {
        try {
            Initialize-SqliteInterop
            [CodexSwitcherSqlite]::Restore($Migration.DatabaseBackup,$Migration.DatabasePath)
        } catch { $errors.Add('数据库恢复失败：' + $_.Exception.Message) }
    }
    if ($Migration.ProjectionPath -and $Migration.ProjectionBackup -and (Test-Path -LiteralPath $Migration.ProjectionBackup)) {
        try {
            Initialize-SqliteInterop
            [CodexSwitcherSqlite]::Restore($Migration.ProjectionBackup,$Migration.ProjectionPath)
        } catch { $errors.Add('会话投影缓存恢复失败：' + $_.Exception.Message) }
    }
    foreach ($entry in @($Migration.Rollouts)) {
        try {
            if (Test-Path -LiteralPath $entry.Backup) {
                Copy-Item -LiteralPath $entry.Backup -Destination $entry.Original -Force
            }
        } catch { $errors.Add('会话文件恢复失败：' + $entry.Original + '；' + $_.Exception.Message) }
    }
    if ($errors.Count -gt 0) { throw ($errors -join "`r`n") }
}
function Migrate-AllChats([string]$CodexRoot,[string]$Provider,[string]$Model,[string]$Effort,[string]$BackupRoot) {
    $script:TimingRows = $null
    $watch = [Diagnostics.Stopwatch]::StartNew()
    if ($Provider -notmatch '^[A-Za-z0-9_.-]+$' -or $Model -notmatch '^[A-Za-z0-9_./:-]+$' -or $Effort -notmatch '^[A-Za-z0-9_.-]+$') {
        throw '目标 provider 或模型名称格式无效，未迁移会话。'
    }
    Report-Progress 2 '正在扫描会话文件…'
    $database = Find-CodexStateDatabase $CodexRoot
    $projection = Find-CodexProjectionDatabase $CodexRoot
    $rolloutFiles = @(Get-RolloutFiles $CodexRoot)
    if (!$database -and $rolloutFiles.Count -eq 0) {
        return [pscustomobject]@{ DatabasePath=$null; DatabaseBackup=$null; DatabaseRows=0; ProjectionPath=$null; ProjectionBackup=$null; ProjectionRows=0; Rollouts=@(); RolloutCount=0; RouteChanges=0; CompatibilityChanges=0; ForksRemapped=0; BackupRoot=$BackupRoot; Skipped=@() }
    }
    if (!$database) { throw '发现会话文件，但没有找到包含 threads 表的 Codex state 数据库。未做修改。' }
    $null = New-Item -ItemType Directory -Path $BackupRoot -Force
    $rolloutBackups = New-Object 'Collections.Generic.List[object]'
    $skipped = New-Object 'Collections.Generic.List[object]'
    foreach ($file in $rolloutFiles) {
        $full = [IO.Path]::GetFullPath($file.FullName)
        $root = [IO.Path]::GetFullPath($CodexRoot).TrimEnd('\') + '\'
        if (!$full.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)) { throw "会话路径不在 Codex 根目录内：$full" }
        $session = Get-SessionHeader $full
        if ($session.Problem) {
            # 损坏或空的会话文件无法迁移；跳过它，不让单个坏文件挡住整次切换。
            $skipped.Add([pscustomobject]@{ Path=$full; Reason=$session.Problem })
            continue
        }
        $relative = $full.Substring($root.Length)
        $backup = Join-Path (Join-Path $BackupRoot 'rollouts') $relative
        $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($backup)) -Force
        Copy-Item -LiteralPath $full -Destination $backup -Force
        $rolloutBackups.Add([pscustomobject]@{ Original=$full; Backup=$backup })
    }
    $backupNote = $rolloutBackups.Count.ToString() + ' 个文件'
    if ($skipped.Count -gt 0) { $backupNote += '，跳过 ' + $skipped.Count + ' 个无法解析的文件' }
    Add-SwitchTiming '备份会话文件' $watch.Elapsed.TotalMilliseconds $backupNote
    Report-Progress 10 ('已备份 ' + $rolloutBackups.Count + ' 个会话文件')
    $watch.Restart()
    $databaseBackup = Join-Path $BackupRoot ([IO.Path]::GetFileName($database))
    $projectionBackup = if ($projection) { Join-Path $BackupRoot ([IO.Path]::GetFileName($projection)) } else { $null }
    $migration = [pscustomobject]@{
        DatabasePath=$database
        DatabaseBackup=$databaseBackup
        DatabaseRows=0
        ProjectionPath=$projection
        ProjectionBackup=$projectionBackup
        ProjectionRows=0
        Rollouts=@($rolloutBackups.ToArray())
        RolloutCount=0
        RouteChanges=0
        CompatibilityChanges=0
        ForksRemapped=0
        BackupRoot=$BackupRoot
        Skipped=@($skipped.ToArray())
    }
    try {
        Initialize-SqliteInterop
        $migration.DatabaseRows = [CodexSwitcherSqlite]::BackupAndUpdate($database,$databaseBackup,$Provider,$Model,$Effort)
        Add-SwitchTiming 'SQLite 索引备份+更新' $watch.Elapsed.TotalMilliseconds ($migration.DatabaseRows.ToString() + ' 行')
        Report-Progress 16 ('已更新 ' + $migration.DatabaseRows + ' 条会话索引')
        $watch.Restart()
        $fileIndex = 0
        $rewriteFailures = 0
        $lastRewriteError = ''
        foreach ($entry in $migration.Rollouts) {
            $fileIndex++
            $percent = 16
            if ($migration.Rollouts.Count -gt 0) { $percent = 16 + [int](64 * $fileIndex / $migration.Rollouts.Count) }
            try {
                $stats = Update-RolloutForTarget $entry.Original $Provider $Model $Effort
            } catch {
                # 单个会话文件坏了（例如最后一行写到一半）不再拖垮整次切换：跳过它，其它会话照常处理。
                $rewriteFailures++
                $lastRewriteError = $_.Exception.Message
                $skipped.Add([pscustomobject]@{ Path=$entry.Original; Reason=('改写失败：' + $lastRewriteError) })
                Add-SwitchTiming ('跳过会话 ' + $fileIndex + '/' + $migration.Rollouts.Count) $watch.Elapsed.TotalMilliseconds '改写失败，已跳过'
                $watch.Restart()
                Report-Progress $percent ('已跳过无法改写的会话 ' + $fileIndex + '/' + $migration.Rollouts.Count)
                continue
            }
            $migration.RouteChanges += $stats.RouteChanges
            $migration.CompatibilityChanges += $stats.CompatibilityChanges
            $migration.RolloutCount++
            $fileBytes = ([IO.FileInfo]$entry.Original).Length
            $sizeText = if ($fileBytes -ge 1MB) { ([Math]::Round($fileBytes / 1MB, 2)).ToString() + ' MB' } else { ([Math]::Round($fileBytes / 1KB, 1)).ToString() + ' KB' }
            Add-SwitchTiming ('改写会话 ' + $fileIndex + '/' + $migration.Rollouts.Count) $watch.Elapsed.TotalMilliseconds ($sizeText + '，路由 ' + $stats.RouteChanges + '，兼容 ' + $stats.CompatibilityChanges)
            $watch.Restart()
            Report-Progress $percent ('改写会话 ' + $fileIndex + '/' + $migration.Rollouts.Count + '（' + $sizeText + '）')
        }
        $migration.Skipped = @($skipped.ToArray())
        if ($migration.Rollouts.Count -gt 0 -and $rewriteFailures -eq $migration.Rollouts.Count) {
            # 全部文件都改写失败更像系统性问题（权限、磁盘、编码），宁可整体回滚也不要留下半套状态。
            throw ('所有会话文件都无法改写（最后一个原因：' + $lastRewriteError + '），已取消并恢复备份。')
        }
        if ($skipped.Count) {
            $skipPaths = @($skipped | ForEach-Object { $_.Path })
            $skipIds = @($skipped | ForEach-Object { $h = Get-SessionHeader $_.Path; if ($h.Header) { [string]$h.Header.payload.id } else { '' } })
            $restored = [CodexSwitcherSqlite]::RestoreSkippedRoutes($database,$databaseBackup,[string[]]$skipPaths,[string[]]$skipIds)
            $migration.DatabaseRows -= $restored
        }
        $migration.ForksRemapped = Repair-ForkHistoryOffsets $migration.Rollouts
        Add-SwitchTiming '修复 fork 偏移' $watch.Elapsed.TotalMilliseconds ($migration.ForksRemapped.ToString() + ' 处')
        Report-Progress 84 '已修复 fork 偏移'
        $watch.Restart()
        if ($projection) {
            $migration.ProjectionRows = [CodexSwitcherSqlite]::BackupAndClearProjection($projection,$projectionBackup)
            Add-SwitchTiming '投影缓存备份+清空' $watch.Elapsed.TotalMilliseconds ($migration.ProjectionRows.ToString() + ' 行')
        }
        Report-Progress 94 '已重建会话投影缓存'
        $manifest = @{
            createdAt=(Get-Date).ToString('o')
            targetProvider=$Provider
            targetModel=$Model
            targetReasoningEffort=$Effort
            databasePath=$database
            databaseRows=$migration.DatabaseRows
            projectionPath=$projection
            projectionRowsInvalidated=$migration.ProjectionRows
            rolloutCount=$migration.RolloutCount
            routeChanges=$migration.RouteChanges
            compatibilityChanges=$migration.CompatibilityChanges
            forksRemapped=$migration.ForksRemapped
            rollouts=@($migration.Rollouts)
        }
        Atomic-Write (Join-Path $BackupRoot 'manifest.json') ($manifest | ConvertTo-Json -Depth 8)
        return $migration
    } catch {
        try { Restore-ChatMigration $migration } catch { Write-Diagnostic 'ERROR' ('Chat rollback failed: ' + $_.Exception.Message) }
        throw
    }
}
function Write-Diagnostic([string]$Level,[string]$Message) {
    try {
        $safe = [string]$Message
        foreach ($secret in @($script:DiagnosticSecrets)) { if ($secret) { $safe = $safe.Replace($secret,'[REDACTED]') } }
        $safe = [regex]::Replace($safe,'(?i)(sk-[A-Za-z0-9_-]+|Bearer\s+[^\s"'']+)','[REDACTED]')
        if ([IO.File]::Exists($script:DiagnosticLog) -and ([IO.FileInfo]$script:DiagnosticLog).Length -gt 5242880) { [IO.File]::Copy($script:DiagnosticLog,$script:DiagnosticLog + '.1',$true); [IO.File]::WriteAllText($script:DiagnosticLog,'',$script:Utf8) }
        $line = '{0} [{1}] pid={2} {3}' -f ([DateTimeOffset]::Now.ToString('o')),$Level,$PID,$safe
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($script:DiagnosticLog)) | Out-Null
        [IO.File]::AppendAllText($script:DiagnosticLog,$line + "`n",$script:Utf8)
    } catch {
        try {
            $fallback = Join-Path $env:LOCALAPPDATA 'Codex-Switcher\logs\runtime.log'
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fallback)) | Out-Null
            [IO.File]::AppendAllText($fallback,$line + "`n",$script:Utf8)
            $script:DiagnosticLog = $fallback
        } catch { [Console]::Error.WriteLine('Unable to write diagnostic log: ' + $script:DiagnosticLog) }
    }
}
function Switch-Mode([string]$ConfigPath,[string]$Mode,[string]$ApiBase,[string]$Model,[string]$Key,[string]$Catalog) {
    $script:DiagnosticSecrets = @($Key)
    try {
        $script:DiagnosticLog = Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ConfigPath))) 'codex-switcher\runtime.log'
        Write-Diagnostic 'INFO' ('Switch requested; mode=' + $Mode + '; config=' + $ConfigPath)
        $message = Invoke-SwitchMode $ConfigPath $Mode $ApiBase $Model $Key $Catalog
        Write-Diagnostic 'INFO' ('Switch finished; mode=' + $Mode)
        return $message
    } catch {
        Write-Diagnostic 'ERROR' ($_.Exception.ToString() + "`n" + $_.ScriptStackTrace)
        throw
    } finally { $script:DiagnosticSecrets = @() }
}
function Invoke-SwitchMode([string]$ConfigPath,[string]$Mode,[string]$ApiBase,[string]$Model,[string]$Key,[string]$Catalog) {
    Assert-Closed
    $ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
    if ([IO.Path]::GetFileName($ConfigPath) -ne 'config.toml' -or !(Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw '请选择实际生效的 config.toml 文件。' }
    $originalBytes = [IO.File]::ReadAllBytes($ConfigPath)
    $original = [IO.File]::ReadAllText($ConfigPath)
    $marker = '(?ms)^# CODEX-SWITCHER-BEGIN\r?\n.*?^# CODEX-SWITCHER-END\r?\n?'
    $clean = [regex]::Replace($original,$marker,'')
    $split = Split-Config $clean
    $configDir = [IO.Path]::GetDirectoryName($ConfigPath)
    $dir = Join-Path $configDir 'codex-switcher'
    $state = Read-State $dir
    $currentProvider = Root-Value $split.Root 'model_provider'
    if ($original -match '(?m)^\s*profile\s*=') { throw '检测到旧版 profile 选择器。请先迁移该配置，工具未修改文件。' }
    $catalogAdded = @()
    $catalogIncomplete = $false
    # 切到官方时旧会话要改用的官方模型；下面两个分支各自负责填好它。
    $officialModel = ''
    $officialModelSource = ''
    $requestedModel = $Model   # 用户在“模型名称”栏里填的内容（切官方时可用于指定官方模型）
    if ($Mode -eq 'deepseek') {
        $uri = $null
        if (![uri]::TryCreate($ApiBase,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'API 地址必须是有效的 HTTPS 基础地址，不得含密码、查询参数或片段。' }
        if ($uri.Host -eq '127.0.0.1' -or $uri.Host -eq 'localhost') { throw '本工具使用直连 HTTPS 接口，不使用旧 CC Switch 地址。' }
        $models = @(Split-ModelList $Model)
        if ($models.Count -eq 0) { throw '请填写 DeepSeek 模型名称。' }
        foreach ($name in $models) { if ($name -notmatch '^[A-Za-z0-9_./:-]+$') { throw ('模型名称格式无效：' + $name) } }
        # 第一个为当前生效模型；其余只用于补进模型目录，方便在对话里下拉选择。
        $Model = $models[0]
        if ($Key -and $Key -match '\s') { throw 'API Key 不能包含空格或换行。' }
        if (!$Key -and !(Test-Path -LiteralPath (Join-Path $dir 'deepseek.key'))) { throw '首次使用请填写 DeepSeek API Key。' }
        if ($Catalog) {
            $catalogObject = Read-CatalogObject $Catalog
            if (!(Get-CompleteCatalogEntry $catalogObject)) { $catalogIncomplete = $true }
            $catalogAdded = @(Add-CatalogModels $catalogObject $models)
            if ($catalogAdded.Count -gt 0) {
                # Catalog is written inside the switch transaction after validation.
            }
            if (!(@(Get-CatalogSlugs $catalogObject) -contains $Model)) { throw '模型目录中缺少当前模型，未做修改。' }
        }
        if ($state -and $currentProvider -in @('deepseek','codex_switcher_deepseek')) { $official = @($state.officialRoot) }
        elseif (!$currentProvider -or $currentProvider -eq 'openai') { $official = @($split.Root) }
        elseif ($state) { $official = @($state.officialRoot) }
        else { throw '首次使用时请从当前官方登录配置开始，工具才能准确保存官方模型设置。' }
        # 官方登录的 config.toml 通常不写 model（模型由服务器下发），所以要么沿用上次记录的官方模型，
        # 要么从当前这份官方配置、桌面应用的默认模型里取，供以后切回官方时使用。
        if ($currentProvider -in @('deepseek','codex_switcher_deepseek')) {
            if ($state -and $state.PSObject.Properties['officialModel']) {
                $officialModel = [string]$state.officialModel
                $officialModelSource = '上次记录'
            }
        } else {
            $officialModel = [string](Root-Value $split.Root 'model')
            if ($officialModel) { $officialModelSource = '官方配置' }
        }
        if ($officialModel -and !(Test-OfficialModelName $configDir $officialModel) -and (Test-OfficialModelKnown $configDir)) {
            # 看起来不是官方模型（例如手工把第三方模型写进了官方配置），不要让它日后被当成官方模型用。
            $officialModel = ''
            $officialModelSource = ''
        }
        if (!$officialModel) {
            $officialModel = Resolve-OfficialModel $configDir
            if ($officialModel) { $officialModelSource = '应用当前官方模型' }
        }
        if ($clean -match '(?m)^\s*\[model_providers\.(deepseek|codex_switcher_deepseek)\]') { throw '配置中出现与工具保留名称重名的 DeepSeek provider。请先移除重名配置，再使用工具。' }
    } else {
        if (!$state -and (!$currentProvider -or $currentProvider -eq 'openai')) { return '当前已经是官方配置，无需修改。' }
        if (!$state) { throw ('未找到本工具保存的官方配置：' + (Join-Path $dir 'state.json') + "`r`n" + '常见原因：第 1 栏选错了 config.toml（选到的不是当前生效的那份），或这台机器没用本工具切换过。' + "`r`n" + '处理办法：在 Codex 里正常登录 ChatGPT 官方账号，把配置里的 model_provider / model / model_catalog_json 等第三方行删掉，再重新打开本工具。工具未修改任何文件。') }
        $official = @($state.officialRoot)
        $ApiBase = [string]$state.apiBase
        $Model = [string]$state.model
        $Catalog = [string]$state.catalog
        # 优先级：保存的官方配置里写的 model -> state 里记录的官方模型 -> 你这次在“模型名称”栏填的官方模型 -> 应用当前的官方默认模型。
        $officialModel = [string](Root-Value $official 'model')
        if ($officialModel) { $officialModelSource = '官方配置' }
        if (!$officialModel -and $state.PSObject.Properties['officialModel']) {
            $officialModel = [string]$state.officialModel
            if ($officialModel) { $officialModelSource = '上次记录' }
        }
        if ($officialModel -and ($officialModel -match '^deepseek' -or @(Get-DeepSeekCatalogSlugs $configDir) -contains $officialModel)) { $officialModel = ''; $officialModelSource = '' }
        if (!$officialModel -and $requestedModel) {
            if ((Test-OfficialModelName $configDir $requestedModel) -or (!(Test-OfficialModelKnown $configDir) -and $requestedModel -match '^gpt-[A-Za-z0-9_.:-]+$' -and $requestedModel -ne [string]$state.model -and @($state.model -split '[,;\s]+') -notcontains $requestedModel -and @(Get-DeepSeekCatalogSlugs $configDir) -notcontains $requestedModel)) {
                $officialModel = $requestedModel
                $officialModelSource = '模型名称栏'
            }
        }
        if (!$officialModel) {
            $officialModel = Resolve-OfficialModel $configDir
            if ($officialModel) { $officialModelSource = '应用当前官方模型' }
        }
        if (!$officialModel) {
            throw ('无法确定官方模式下旧会话应该用哪个模型：保存的官方配置里没有 model，本机也没有可用的官方模型记录。' + "`r`n" + '处理办法（二选一）：' + "`r`n" + '  1. 先在 Codex 里登录 ChatGPT 官方账号并选择一次模型，让 Codex 写出模型缓存，再运行本工具；' + "`r`n" + '  2. 在第 2 栏“模型名称”里填写要迁移到的官方模型名（例如 gpt-5.6-sol），然后点“切换到官方登录”。' + "`r`n" + '工具未修改任何文件。')
        }
    }
    # The bounded provider definitions remain in both modes so persisted DeepSeek threads can resume.
    $helper = Join-Path $dir 'credential-helper.ps1'
    $keyPath = Join-Path $dir 'deepseek.key'
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $providerLines = @(
        '# CODEX-SWITCHER-BEGIN',
        '[model_providers.deepseek]',
        'name = "DeepSeek"',
        ('base_url = ' + (Quote-Toml $ApiBase.TrimEnd('/'))),
        'wire_api = "responses"',
        '[model_providers.deepseek.auth]',
        ('command = ' + (Quote-Toml $psExe)),
        ('args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ' + (Quote-Toml $helper) + ', "-EmitKey", "-KeyFile", ' + (Quote-Toml $keyPath) + ']'),
        'timeout_ms = 10000',
        'refresh_interval_ms = 0',
        '',
        '# Compatibility alias for chats created by Codex Switcher v1.',
        '[model_providers.codex_switcher_deepseek]',
        'name = "DeepSeek (Switcher v1 compatibility)"',
        ('base_url = ' + (Quote-Toml $ApiBase.TrimEnd('/'))),
        'wire_api = "responses"',
        '[model_providers.codex_switcher_deepseek.auth]',
        ('command = ' + (Quote-Toml $psExe)),
        ('args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ' + (Quote-Toml $helper) + ', "-EmitKey", "-KeyFile", ' + (Quote-Toml $keyPath) + ']'),
        'timeout_ms = 10000',
        'refresh_interval_ms = 0',
        '# CODEX-SWITCHER-END'
    )
    $extra = $providerLines -join "`r`n"
    if ($Mode -eq 'deepseek') {
        $roots = @('model_provider = "deepseek"', ('model = ' + (Quote-Toml $Model)), 'model_reasoning_effort = "high"', 'web_search = "disabled"')
        # web_search must also be treated as switchable to avoid duplicate top-level keys.
        if ($Catalog) { $roots += 'model_catalog_json = ' + (Quote-Toml (Join-Path $dir 'deepseek-models.json')) }
        $updated = Make-Config $clean $roots ($extra + "`r`n")
    } else { $updated = Make-Config $clean $official ($extra + "`r`n") }
    # 顶层键重复会让 Codex 启动失败；宁可取消，也不要写出坏配置。
    $duplicates = @(Get-DuplicateRootKeys $updated)
    if ($duplicates.Count -gt 0) { throw ('生成的 config.toml 出现重复的顶层配置项：' + ($duplicates -join '、') + '。已取消，未修改任何文件。') }
    $null = New-Item -ItemType Directory -Path $dir -Force
    $backupDir = Join-Path $dir 'backups'
    $null = New-Item -ItemType Directory -Path $backupDir -Force
    $backup = Join-Path $backupDir ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.toml')
    [IO.File]::WriteAllBytes($backup,$originalBytes)
    $nextState = @{ officialRoot=@($official); mode=$Mode; apiBase=$ApiBase; model=$Model; catalog=$Catalog; lastBackup=$backup; officialModel=$officialModel; officialModelSource=$officialModelSource }
    if ($Mode -eq 'deepseek') {
        $targetProvider = 'deepseek'
        $targetModel = $Model
        $targetEffort = 'high'
    } else {
        $targetProvider = 'openai'
        $targetModel = $officialModel
        $targetEffort = [string](Root-Value $official 'model_reasoning_effort')
        if (!$targetEffort) { $targetEffort = 'medium' }
    }
    # Recheck before touching chat state so application writes aren't silently lost.
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($ConfigPath)) -ne [Convert]::ToBase64String($originalBytes)) { throw '配置在切换期间被其他程序修改，已取消；请退出应用后重试。' }
    Assert-Closed
    $chatBackupRoot = Join-Path (Join-Path $dir 'chat-backups') ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6))
    $null = New-Item -ItemType Directory -Path $chatBackupRoot -Force
    $statePath = Join-Path $dir 'state.json'
    $fileBackups = @()
    $paths = @($statePath,$helper,$keyPath,(Join-Path $dir 'deepseek-models.json'))
    if ($Catalog) { $paths += [IO.Path]::GetFullPath($Catalog) }
    foreach ($path in @($paths | Select-Object -Unique)) {
        $exists = [IO.File]::Exists($path)
        $saved = Join-Path $chatBackupRoot ('file-' + $fileBackups.Count + '.before-switch')
        if ($exists) { Copy-Item -LiteralPath $path -Destination $saved -Force }
        $fileBackups += [pscustomobject]@{ Path=$path; Backup=$saved; Existed=$exists }
    }
    $migration = $null
    try {
        Assert-Closed
        if ($Mode -eq 'deepseek') {
            Copy-Item -LiteralPath $script:SourceScript -Destination $helper -Force
            if ($Key) { Atomic-Write $keyPath (ConvertFrom-SecureString (ConvertTo-SecureString $Key -AsPlainText -Force)) }
            if ($Catalog) {
                if ($catalogAdded.Count -gt 0) {
                    $catalogBackup = Backup-CatalogFile $Catalog $dir
                    if (!$catalogBackup) { throw 'Cannot back up model catalog; switch cancelled.' }
                    Atomic-Write $Catalog (Convert-ToLfText ($catalogObject | ConvertTo-Json -Depth 25))
                }
                Atomic-Write (Join-Path $dir 'deepseek-models.json') (Convert-ToLfText ([IO.File]::ReadAllText($Catalog)))
            }
        }
        $migration = Migrate-AllChats $configDir $targetProvider $targetModel $targetEffort $chatBackupRoot
        Assert-Closed
        Atomic-Write $statePath ($nextState | ConvertTo-Json -Depth 6)
        Atomic-Write $ConfigPath $updated
    } catch {
        $failure = $_
        $rollbackErrors = @()
        try { Restore-ChatMigration $migration } catch { $rollbackErrors += $_.Exception.Message }
        try { Copy-Item -LiteralPath $backup -Destination $ConfigPath -Force } catch { $rollbackErrors += $_.Exception.Message }
        foreach ($entry in $fileBackups) {
            try {
                if ($entry.Existed) { Copy-Item -LiteralPath $entry.Backup -Destination $entry.Path -Force }
                elseif ([IO.File]::Exists($entry.Path)) { [IO.File]::Delete($entry.Path) }
            } catch { $rollbackErrors += $_.Exception.Message }
        }
        Write-Diagnostic 'INFO' ('Rollback finished; errors=' + $rollbackErrors.Count)
        if ($rollbackErrors.Count) { Write-Diagnostic 'ERROR' ('Rollback incomplete: ' + ($rollbackErrors -join '; ')) }
        throw $failure
    }
    $timingText = Format-SwitchTiming
    $totalSeconds = [Math]::Round((Get-SwitchTimingTotalMs) / 1000, 2)
    $timingLog = Join-Path $dir 'switch-timing.log'
    if ($timingText) {
        $entry = '=== ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  切到 ' + $Mode + '（' + $targetProvider + ' / ' + $targetModel + ' / ' + $targetEffort + '）' + "`r`n" + $timingText + "`r`n  合计 " + $totalSeconds + " 秒`r`n`r`n"
        try { [IO.File]::AppendAllText($timingLog,$entry,$script:Utf8) } catch { }
    }
    try { Write-Log $dir ('Switched to ' + $Mode + '; backup=' + $backup + '; totalMs=' + [Math]::Round((Get-SwitchTimingTotalMs),0)) } catch { Write-Diagnostic 'WARN' ('Success log failed: ' + $_.Exception.Message) }
    if (@($migration.Skipped).Count -gt 0) {
        try { Write-Log $dir ('Skipped ' + @($migration.Skipped).Count + ' unreadable session file(s): ' + ((@($migration.Skipped) | ForEach-Object { $_.Path + ' (' + $_.Reason + ')' }) -join ' | ')) } catch { }
    }
    Report-Progress 100 '完成'
    $catalogNote = ''
    if ($Mode -eq 'deepseek') {
        if ($catalogAdded.Count -gt 0) {
            $catalogNote = "`r`n已把新模型写进模型目录并同步到生效副本：" + ($catalogAdded -join '、')
        }
        if ($catalogIncomplete) {
            $catalogNote += "`r`n注意：这个目录里的条目缺少 Codex 需要的能力元数据；新条目已按工具自带目录补齐，"
            $catalogNote += "但原有条目本身没有补。如果 Codex 启动报模型目录错误，请改用工具自带目录，或按自带条目的字段补齐。"
        }
        if ($Catalog) { $catalogNote += "`r`n模型目录：$Catalog（原文件已备份到 codex-switcher\catalog-backups）" }
        else { $catalogNote += "`r`n未指定模型目录：对话里的模型下拉可能列不出这个模型，但请求仍按 $targetModel 发送。" }
    } else {
        $catalogNote = "`r`n旧会话改用官方模型 $targetModel（来源：$officialModelSource）；配置里不再写 model_catalog_json，Codex 会重新使用官方模型列表。"
        $catalogNote += "`r`n如需换成别的官方模型，重新打开 Codex 后在对话框上方的模型列表里选一次即可。"
    }
    if (@($migration.Skipped).Count -gt 0) {
        $catalogNote += "`r`n已跳过 " + @($migration.Skipped).Count + ' 个无法解析的会话文件（损坏或空文件），不影响其它会话：' + "`r`n" + (Format-SkippedSessions $migration.Skipped)
        $catalogNote += "`r`n这些文件没有被修改，也不会被迁移；如果是 0 字节的空文件，可以直接删掉（Codex 用不到它）。"
    }
    return "切换成功，耗时 $totalSeconds 秒。现在请重新打开 Codex。`r`n已将 $($migration.DatabaseRows) 条会话索引和 $($migration.RolloutCount) 个现有会话文件切到 $targetProvider / $targetModel（$targetEffort）。`r`n兼容字段处理 $($migration.CompatibilityChanges) 处，fork 偏移修复 $($migration.ForksRemapped) 个，投影缓存失效 $($migration.ProjectionRows) 行。`r`n可见历史消息、官方登录凭证、skills 和 MCP 均保留。$catalogNote`r`n配置备份：$backup`r`n会话备份：$($migration.BackupRoot)`r`n耗时明细：$timingLog"
}
function Get-CheckRootKey([string[]]$Lines,[string]$Name) {
    foreach ($line in $Lines) {
        $trim = $line.Trim()
        if ($trim.StartsWith('[')) { return $null }
        $match = [regex]::Match($trim,'^["'']?' + [regex]::Escape($Name) + '["'']?\s*=\s*"([^"]*)"')
        if ($match.Success) { return $match.Groups[1].Value }
    }
    return $null
}
function Get-CheckProviderSection([string[]]$Lines,[string]$Provider) {
    $header = '[model_providers.' + $Provider + ']'
    $inside = $false
    $found = @{}
    foreach ($line in $Lines) {
        $trim = $line.Trim()
        if ($trim.StartsWith('[')) { $inside = ($trim -eq $header); continue }
        if (!$inside) { continue }
        $match = [regex]::Match($trim,'^(base_url|wire_api|name)\s*=\s*"([^"]*)"')
        if ($match.Success) { $found[$match.Groups[1].Value] = $match.Groups[2].Value }
    }
    return $found
}
function Get-CheckConfigInfo([string]$Root) {
    $path = Join-Path $Root 'config.toml'
    $info = [pscustomobject]@{
        Path=$path; Provider='?'; Model='?'; Effort=''
        BaseUrl='（未配置，由官方登录提供）'; Wire='ChatGPT 官方登录'
    }
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return $info }
    $lines = [IO.File]::ReadAllLines($path,$script:Utf8)
    $provider = Get-CheckRootKey $lines 'model_provider'
    if ($provider) { $info.Provider = $provider }
    $model = Get-CheckRootKey $lines 'model'
    if ($model) { $info.Model = $model }
    $effort = Get-CheckRootKey $lines 'model_reasoning_effort'
    if ($effort) { $info.Effort = $effort }
    if ($provider) {
        $section = Get-CheckProviderSection $lines $provider
        if ($section.ContainsKey('base_url')) { $info.BaseUrl = $section['base_url'] }
        $wire = if ($section.ContainsKey('wire_api')) { $section['wire_api'] } else { 'responses' }
        $info.Wire = 'wire_api=' + $wire
    }
    return $info
}
function Get-CheckRolloutFiles([string]$Root) {
    $list = New-Object 'Collections.Generic.List[IO.FileInfo]'
    foreach ($name in @('sessions','archived_sessions')) {
        $dir = Join-Path $Root $name
        if (Test-Path -LiteralPath $dir -PathType Container) {
            foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter 'rollout-*.jsonl' -File -Recurse -ErrorAction SilentlyContinue)) {
                $list.Add($file)
            }
        }
    }
    return @($list.ToArray())
}
function Open-CheckReader([string]$Path) {
    $last = $null
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            $handle = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
            return (New-Object IO.StreamReader($handle,$script:Utf8,$true,65536))
        } catch {
            $last = $_
            Start-Sleep -Milliseconds 250
        }
    }
    throw ('无法读取会话文件（可能正被 Codex 写入）：' + $Path + '；' + $last.Exception.Message)
}
function Get-CheckHeader([string]$Path) {
    $reader = Open-CheckReader $Path
    try { $line = $reader.ReadLine() } finally { $reader.Dispose() }
    try { return ($line | ConvertFrom-Json).payload } catch { return $null }
}
function Get-CheckFingerprint([string]$Id) {
    if ($Id -match '^resp_[0-9a-fA-F]{16,}$') { return 'OpenAI官方(resp_)' }
    if ($Id -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { return 'UUID(非OpenAI官方)' }
    return '其他格式'
}
function Get-CheckProviderLabel([string]$Kind) {
    if ($Kind -like 'OpenAI官方*') { return 'OpenAI 官方' }
    if ($Kind -like 'UUID*') { return 'UUID 响应（来源未验证）' }
    return '未知来源'
}
function Read-CheckResponseIds([string]$Path,[int]$TailBytes=0,[int]$MaxCount=0) {
    $list = New-Object 'Collections.Generic.List[object]'
    $handle = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {
        $skipFirst = $false
        if ($TailBytes -gt 0 -and $handle.Length -gt $TailBytes) {
            $handle.Seek($handle.Length - $TailBytes,[IO.SeekOrigin]::Begin) | Out-Null
            $skipFirst = $true
        }
        $reader = New-Object IO.StreamReader($handle,$script:Utf8,$true,65536)
        try {
            $first = $true
            while (($line = $reader.ReadLine()) -ne $null) {
                if ($first) { $first = $false; if ($skipFirst) { continue } }
                if ($line.IndexOf('"response_id"',[StringComparison]::Ordinal) -lt 0) { continue }
                $record = $null
                try { $record = $line | ConvertFrom-Json } catch { continue }
                if (!$record -or !$record.payload) { continue }
                $id = [string]$record.payload.response_id
                if (!$id) { continue }
                $when = $null
                try { $when = ([datetimeoffset]::Parse([string]$record.timestamp)).LocalDateTime } catch { }
                $list.Add([pscustomobject]@{ Ts=$when; Id=$id })
            }
        } finally { $reader.Dispose() }
    } finally { $handle.Dispose() }
    $items = @($list.ToArray())
    if ($MaxCount -gt 0 -and $items.Count -gt $MaxCount) {
        return @($items[($items.Count - $MaxCount)..($items.Count - 1)])
    }
    return $items
}
function Format-CheckWhen($Value) {
    if ($null -eq $Value) { return '??:??:??' }
    return ([datetime]$Value).ToString('HH:mm:ss')
}
function Get-CheckThreadRuntime([string]$Path,[int]$MaxScanBytes = 8388608) {
    # 对话界面里选的模型存在会话自己的运行时设置里（turn_context / thread_settings_applied），
    # 与 config.toml 的默认模型是两回事。这里从文件末尾向前找最后一条运行时记录。
    $result = [pscustomobject]@{ Found=$false; Model=''; Provider=''; Effort=''; When=$null }
    if (!$Path -or !(Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }
    $length = ([IO.FileInfo]$Path).Length
    if ($length -le 0) { return $result }
    $window = [int][Math]::Min([double]$MaxScanBytes,[double]$length)
    $handle = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {
        $handle.Seek($length - $window,[IO.SeekOrigin]::Begin) | Out-Null
        $buffer = New-Object byte[] $window
        $read = 0
        while ($read -lt $window) {
            $n = $handle.Read($buffer,$read,$window - $read)
            if ($n -le 0) { break }
            $read += $n
        }
    } finally { $handle.Dispose() }
    $lines = [regex]::Split($script:Utf8.GetString($buffer,0,$read),'\r?\n')
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        $isTurn = $line.IndexOf('"turn_context"',[StringComparison]::Ordinal) -ge 0
        $isSettings = $line.IndexOf('thread_settings_applied',[StringComparison]::Ordinal) -ge 0
        if (!$isTurn -and !$isSettings) { continue }
        $record = $null
        try { $record = $line | ConvertFrom-Json } catch { continue }
        if (!$record -or !$record.payload) { continue }
        if ($isTurn -and $record.type -eq 'turn_context') {
            if (!$result.Model -and $record.payload.model) { $result.Model = [string]$record.payload.model }
            if (!$result.Effort -and $record.payload.effort) { $result.Effort = [string]$record.payload.effort }
            if (!$result.When) { try { $result.When = ([datetimeoffset]::Parse([string]$record.timestamp)).LocalDateTime } catch { } }
        } elseif ($record.type -eq 'event_msg' -and $record.payload.PSObject.Properties['thread_settings']) {
            $settings = $record.payload.thread_settings
            if (!$result.Model -and $settings.model) { $result.Model = [string]$settings.model }
            if (!$result.Provider -and $settings.model_provider_id) { $result.Provider = [string]$settings.model_provider_id }
            if (!$result.Effort -and $settings.reasoning_effort) { $result.Effort = [string]$settings.reasoning_effort }
            if (!$result.When) { try { $result.When = ([datetimeoffset]::Parse([string]$record.timestamp)).LocalDateTime } catch { } }
        }
        # 最后一次出现的运行时记录即当前选择；provider 缺失时继续向前找 settings 记录补齐。
        if ($result.Model -and $result.Provider) { break }
    }
    $result.Found = [bool]$result.Model
    return $result
}
function Get-ProviderSnapshot([string]$CodexRoot,[int]$Recent=6,[int]$TailBytes=262144,[switch]$Full) {
    $root = [IO.Path]::GetFullPath($CodexRoot)
    $config = Get-CheckConfigInfo $root
    $lines = New-Object 'Collections.Generic.List[string]'
    $lines.Add('配置文件      : ' + $config.Path)
    $lines.Add('新对话默认模型: ' + $config.Model + '   （来自 config.toml，只影响新建对话）')
    $lines.Add('新对话默认来源: ' + $config.Provider)
    if ($config.Effort) { $lines.Add('默认推理强度  : ' + $config.Effort) }
    $lines.Add('接口地址      : ' + $config.BaseUrl)
    $lines.Add('认证方式      : ' + $config.Wire)
    $lines.Add('')
    $result = [pscustomobject]@{
        Lines=$lines.ToArray(); Provider=$config.Provider; Model=$config.Model; BaseUrl=$config.BaseUrl
        ThreadId=''; ThreadFile=''; OriginModel=''; LastId=''; LastKind=''
        ThreadModel=''; ThreadProvider=''; ThreadEffort=''
        Headline='未找到会话文件'; Conclusion='无法判断'
    }
    $files = @(Get-CheckRolloutFiles $root)
    if ($files.Count -eq 0) {
        $lines.Add('没有找到会话文件（rollout-*.jsonl）。先让 Codex 产生一次对话，再刷新。')
        $result.Lines = $lines.ToArray()
        return $result
    }
    $target = @($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1)[0]
    $header = Get-CheckHeader $target.FullName
    $threadId = if ($header) { [string]$header.id } else { '?' }
    $origin = if ($header -and $header.base_instructions -and $header.base_instructions.provenance -and $header.base_instructions.provenance.model) {
        [string]$header.base_instructions.provenance.model
    } else { '（未记录）' }
    $lines.Add('会话文件      : ' + $target.Name)
    $lines.Add('会话 ID       : ' + $threadId)
    $runtime = Get-CheckThreadRuntime $target.FullName
    $result.ThreadModel = [string]$runtime.Model
    $result.ThreadProvider = if ($runtime.Provider) { [string]$runtime.Provider } else { [string]$header.model_provider }
    $result.ThreadEffort = [string]$runtime.Effort
    if ($runtime.Found) {
        $providerText = if ($runtime.Provider) { $runtime.Provider } else { '（未记录）' }
        $effortText = if ($runtime.Effort) { $runtime.Effort } else { '（未记录）' }
        $whenText = if ($runtime.When) { '  记录于 ' + (Format-CheckWhen $runtime.When) } else { '' }
        $lines.Add('本对话实际模型: ' + $runtime.Model + '   provider=' + $providerText + '   推理=' + $effortText + '   （会话运行时记录，即对话里选的那个）' + $whenText)
    } else {
        $lines.Add('本对话实际模型: （这个会话文件里还没有运行时记录；先在 Codex 里发一条消息或改一次模型再刷新）')
    }
    $lines.Add('创建时模型    : ' + $origin + '  （取自会话头，切换工具不会修改，可交叉验证）')
    if ($runtime.Found -and $runtime.Model -and $config.Model -and $runtime.Model -ne $config.Model) {
        $lines.Add('提示          : 本对话用的是 ' + $runtime.Model + '；config.toml 的 ' + $config.Model + ' 只影响新建对话。')
    }
    if ($runtime.Found -and $runtime.Provider -and $config.Provider -and $config.Provider -ne '?' -and $runtime.Provider -ne $config.Provider) {
        $lines.Add('提示          : 本对话记录的 provider 是 ' + $runtime.Provider + '，与 config.toml 的 ' + $config.Provider + ' 不同。')
    }
    $lines.Add('')
    $window = @(Read-CheckResponseIds $target.FullName $TailBytes 0)
    $result.ThreadId = $threadId
    $result.ThreadFile = $target.FullName
    $result.OriginModel = $origin
    if ($window.Count -eq 0) {
        $lines.Add('这个会话还没有服务端签发的响应 ID，无法判断。先在 Codex 里发一条消息再刷新。')
        $result.Lines = $lines.ToArray()
        $result.Headline = '尚无响应记录'
        return $result
    }
    $recentEntries = if ($window.Count -gt $Recent) { @($window[($window.Count - $Recent)..($window.Count - 1)]) } else { $window }
    $latest = $window[$window.Count - 1]
    $latestKind = Get-CheckFingerprint $latest.Id
    $result.LastId = $latest.Id
    $result.LastKind = $latestKind
    $lines.Add('最近 ' + $recentEntries.Count + ' 次请求（响应 ID 由对方服务器签发）：')
    foreach ($entry in $recentEntries) {
        $lines.Add('  ' + (Format-CheckWhen $entry.Ts) + '  ' + $entry.Id + '  ' + (Get-CheckFingerprint $entry.Id))
    }
    $lines.Add('')
    $counts = @{}
    foreach ($entry in $window) {
        $key = Get-CheckFingerprint $entry.Id
        if (!$counts.ContainsKey($key)) { $counts[$key] = 0 }
        $counts[$key]++
    }
    $parts = New-Object 'Collections.Generic.List[string]'
    foreach ($key in @($counts.Keys)) { $parts.Add($key + ' x ' + $counts[$key]) }
    $lines.Add('尾部窗口统计（最近 ' + $window.Count + ' 次）: ' + ($parts.ToArray() -join '  +  '))
    if ($Full) {
        $allEntries = @(Read-CheckResponseIds $target.FullName 0 0)
        if ($allEntries.Count -gt 0) {
            $lines.Add('')
            $lines.Add('完整时间线（全部 ' + $allEntries.Count + ' 次请求）：')
            $runs = New-Object 'Collections.Generic.List[object]'
            foreach ($entry in $allEntries) {
                $key = Get-CheckFingerprint $entry.Id
                if ($runs.Count -gt 0 -and $runs[$runs.Count - 1].Kind -eq $key) {
                    $runs[$runs.Count - 1].Count++
                    $runs[$runs.Count - 1].Last = $entry.Ts
                } else {
                    $runs.Add([pscustomobject]@{ Kind=$key; First=$entry.Ts; Last=$entry.Ts; Count=1 })
                }
            }
            foreach ($run in $runs) {
                $lines.Add('  ' + ([datetime]$run.First).ToString('MM-dd HH:mm:ss') + ' ~ ' + ([datetime]$run.Last).ToString('MM-dd HH:mm:ss') + '   ' + ([string]$run.Kind).PadRight(22) + ([string]$run.Count).PadLeft(5) + ' 次')
            }
        }
    }
    $lines.Add('')
    $label = Get-CheckProviderLabel $latestKind
    $threadModelText = if ($result.ThreadModel) { $result.ThreadModel } else { '（未记录）' }
    $threadText = '本对话模型 ' + $threadModelText
    if ($latestKind -like 'OpenAI官方*') {
        $result.Conclusion = '响应 ID 符合 OpenAI 格式（来源尚未验证）'
        $lines.Add('结论：最近响应 ID 符合 OpenAI 格式，不能单独证明后端身份（' + $threadText + '）。')
    } elseif ($latestKind -like 'UUID*') {
        $result.Conclusion = '会话记录的供应商：' + $(if ($runtime.Provider) { $runtime.Provider } else { $header.model_provider })
        $lines.Add('结论：最近响应 ID 是 UUID 格式，不能单独确定后端身份。')
        $lines.Add('      会话记录的供应商/模型：' + $(if ($runtime.Provider) { $runtime.Provider } else { $header.model_provider }) + ' / ' + $threadModelText + '；这是会话记录，不代表已验证的网络目的地。')
    } else {
        $result.Conclusion = '无法判定'
        $lines.Add('结论：最近一次响应 ID 为其他格式（' + $latest.Id + '），无法据此判定。')
    }
    $lines.Add('')
    $lines.Add('提示：响应 ID 格式仅供参考，当前配置也不能证明历史请求的实际去向；')
    $lines.Add('      若第三方接口刻意模仿官方格式，指纹会失真，可用 Clash 的“连接”页看目标域名交叉验证。')
    $result.Lines = $lines.ToArray()
    $result.Headline = '最近响应：' + $label + ' / 会话供应商：' + $result.ThreadProvider + '   ' + (Format-CheckWhen $latest.Ts)
    return $result
}
function Add-ProviderWatchLog([string]$CodexRoot,$Snapshot) {
    try {
        $dir = Join-Path $CodexRoot 'codex-switcher'
        $null = New-Item -ItemType Directory -Path $dir -Force
        $thread = if ($Snapshot.ThreadModel) { $Snapshot.ThreadModel } else { '（未记录）' }
        $line = '{0}  provider={1}  model={2}  base_url={3}  会话={4}  响应ID={5}  对话模型={6}  {7}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Snapshot.ThreadProvider,$Snapshot.ThreadModel,'(see historical request; current config is not proof)',$Snapshot.ThreadId,$Snapshot.LastId,$thread,$Snapshot.LastKind
        [IO.File]::AppendAllText((Join-Path $dir 'provider-watch.log'),$line + "`r`n",$script:Utf8)
    } catch { }
}
$script:ManagedKeys += 'web_search'
. (Join-Path $PSScriptRoot 'ProviderProfiles.ps1')
if ($LibraryOnly) { return }
Write-Diagnostic 'INFO' ('Starting Switcher; PowerShell=' + $PSVersionTable.PSVersion)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$form = New-Object Windows.Forms.Form
$form.Text = 'Codex 多供应商切换'
$form.ClientSize = New-Object Drawing.Size(690,770)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI',10)
function Label([string]$Text,[int]$Y) {
    $control = New-Object Windows.Forms.Label
    $control.Text=$Text; $control.Location=New-Object Drawing.Point(20,$Y); $control.Size=New-Object Drawing.Size(645,26)
    $form.Controls.Add($control)
}
function TextBox([int]$Y,[string]$Value,[int]$Width=550) {
    $control=New-Object Windows.Forms.TextBox
    $control.Text=$Value; $control.Location=New-Object Drawing.Point(20,$Y); $control.Size=New-Object Drawing.Size($Width,28)
    $form.Controls.Add($control); return $control
}
function Browse($Target,[string]$Filter) {
    $dialog=New-Object Windows.Forms.OpenFileDialog
    $dialog.Filter=$Filter
    if ($dialog.ShowDialog() -eq 'OK') { $Target.Text=$dialog.FileName }
    $dialog.Dispose()
}
Label '1. 先正常退出 Codex，再选择当前实际使用的配置文件' 15
$defaultHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$configBox=TextBox 45 (Join-Path $defaultHome 'config.toml')
$browseConfig=New-Object Windows.Forms.Button
$browseConfig.Text='选择文件'; $browseConfig.SetBounds(580,43,90,31)
$browseConfig.Add_Click({ Browse $configBox 'Codex 配置|config.toml' })
$form.Controls.Add($browseConfig)
Label '2. 供应商接口地址（须支持 Responses API）' 88
$baseBox=TextBox 118 'https://api.deepseek.com' 650
Label '模型列表（逗号分隔，第一个为默认模型；切官方时可填目标官方模型）' 155
$modelBox=TextBox 182 'deepseek-v4-flash' 650
Label 'API Key（首次填写；后续留空沿用已保存密钥；不会显示或写入日志）' 220
$keyBox=TextBox 248 '' 650
$keyBox.UseSystemPasswordChar=$true
Label '模型能力目录 JSON（可选；MiMo 等供应商需选官方提供的目录）' 285
$catalogBox=TextBox 313 ''
$browseCatalog=New-Object Windows.Forms.Button
$browseCatalog.Text='选择文件'; $browseCatalog.SetBounds(580,311,90,31)
$browseCatalog.Add_Click({ Browse $catalogBox '模型目录|*.json' })
$form.Controls.Add($browseCatalog)
$notice=New-Object Windows.Forms.Label
$notice.SetBounds(20,348,650,58)
$notice.Text="默认只切新对话配置；旧会话保留原供应商记录。`r`n勾选迁移会改写全部历史会话，跨供应商可能损失推理状态；务必先退出 Codex。"
$form.Controls.Add($notice)
$progress=New-Object Windows.Forms.ProgressBar
$progress.SetBounds(20,410,650,18)
$progress.Minimum=0; $progress.Maximum=100
$form.Controls.Add($progress)
$officialButton=New-Object Windows.Forms.Button
$officialButton.Text='切换到官方登录'; $officialButton.SetBounds(20,438,310,49)
$deepseekButton=New-Object Windows.Forms.Button
$deepseekButton.Text='切换到所选供应商'; $deepseekButton.SetBounds(350,438,320,49)
$form.Controls.AddRange(@($officialButton,$deepseekButton))
$status=New-Object Windows.Forms.Label
$status.SetBounds(20,543,650,25); $form.Controls.Add($status)
$monitorButton=New-Object Windows.Forms.Button
$monitorButton.Text='请求去向监测 — 看这个对话到底发给了谁'
$monitorButton.SetBounds(20,490,650,42)
$monitorButton.Add_Click({ Show-Monitor })
$form.Controls.Add($monitorButton)
# Profile management controls; stable ID is separate from the editable display name.
Label '已保存的供应商（选择后可修改，保存或切换；密钥留空沿用）' 575
$profileBox=New-Object Windows.Forms.ComboBox
$profileBox.SetBounds(20,604,280,30); $profileBox.DropDownStyle='DropDownList'
$form.Controls.Add($profileBox)
$idBox=TextBox 641 '' 170
$nameBox=TextBox 678 '' 280
Label 'ID（新增时填写）                          名称在下方填写' 636
# Labels must not obscure the input fields.
$idBox.BringToFront(); $nameBox.BringToFront()
$newButton=New-Object Windows.Forms.Button; $newButton.Text='新增';$newButton.SetBounds(310,603,85,31)
$saveButton=New-Object Windows.Forms.Button; $saveButton.Text='保存修改';$saveButton.SetBounds(405,603,120,31)
$modelsButton=New-Object Windows.Forms.Button; $modelsButton.Text='获取模型';$modelsButton.SetBounds(535,603,135,31)
$form.Controls.AddRange(@($newButton,$saveButton,$modelsButton))
$migrateBox=New-Object Windows.Forms.CheckBox; $migrateBox.Text='同时迁移全部历史会话（可选）';$migrateBox.SetBounds(310,678,355,30)
$form.Controls.Add($migrateBox)
$script:LoadingProfiles=$false
function Show-ProfileSelection {
    if($script:LoadingProfiles){return}
    $keyBox.Clear()
    if($profileBox.SelectedIndex -eq 0){
        $idBox.Text='openai';$idBox.ReadOnly=$true;$nameBox.Text='OpenAI 官方登录'
        $baseBox.Text='';$modelBox.Text='';$catalogBox.Text=''
        return
    }
    $p=@($script:ProfileStore.profiles)[$profileBox.SelectedIndex-1]
    if(!$p){return}
    $idBox.Text=$p.id; $idBox.ReadOnly=$true; $nameBox.Text=$p.name
    $baseBox.Text=$p.baseUrl; $modelBox.Text=$p.models -join ', ';$catalogBox.Text=$p.catalog
    if($p.catalog -and ![IO.File]::Exists($p.catalog)){
        $cached=Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($configBox.Text))) ('codex-switcher\catalogs\'+$p.id+'.json')
        if([IO.File]::Exists($cached)){$catalogBox.Text=$cached}
    }
    $status.Text='已加载：'+$p.name+'；密钥已加密保存，留空沿用。'
}
function Refresh-ProfileList([string]$Selected) {
    $script:LoadingProfiles=$true
    $profileBox.Items.Clear();$null=$profileBox.Items.Add('OpenAI 官方登录')
    $index=0;$n=0
    foreach($p in @($script:ProfileStore.profiles)){$n++;$null=$profileBox.Items.Add($p.name+' ['+$p.id+']');if($p.id -eq $Selected){$index=$n}}
    $profileBox.SelectedIndex=$index
    $script:LoadingProfiles=$false
    Show-ProfileSelection
}
function Load-Settings {
    try {
        $script:ProfileStore=Get-ProfileStore $configBox.Text
        $script:DiagnosticLog=Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($configBox.Text))) 'codex-switcher\runtime.log'
        Refresh-ProfileList $script:ProfileStore.selected
        Write-Diagnostic INFO 'Provider profiles loaded'
    } catch { Write-Diagnostic ERROR ($_.Exception.ToString()+"`n"+$_.ScriptStackTrace);$status.Text='加载失败：'+$_.Exception.Message }
}
function Read-ProfileEditor {
    $previous=@($script:ProfileStore.profiles | Where-Object {$_.id -eq $idBox.Text}) | Select-Object -First 1
    return New-ProviderProfile $idBox.Text.Trim() $nameBox.Text $baseBox.Text.Trim() $modelBox.Text.Trim() $keyBox.Text.Trim() $catalogBox.Text.Trim() $previous
}
$profileBox.Add_SelectedIndexChanged({Show-ProfileSelection})
$newButton.Add_Click({
    $script:LoadingProfiles=$true;$profileBox.SelectedIndex=-1;$script:LoadingProfiles=$false
    $idBox.ReadOnly=$false;$idBox.Text='';$nameBox.Text='';$baseBox.Text='';$modelBox.Text='';$keyBox.Clear();$catalogBox.Text=''
    $status.Text='填写 ID、名称、接口、模型和密钥，然后保存或直接切换。'
})
$saveButton.Add_Click({
    try {
        if($idBox.Text -eq 'openai'){throw '官方登录使用现有 ChatGPT 登录，无需保存 API Key。'}
        $draft=($script:ProfileStore|ConvertTo-Json -Depth 30|ConvertFrom-Json)
        $p=Read-ProfileEditor;Set-ProviderProfile $draft $p;Save-ProfileStore $configBox.Text $draft
        $script:ProfileStore=$draft;$keyBox.Clear();Refresh-ProfileList $p.id;$status.Text='档案已保存；点击切换后才会应用到 Codex。'
    } catch {Write-Diagnostic ERROR $_.Exception.Message;[Windows.Forms.MessageBox]::Show($_.Exception.Message,'保存失败')|Out-Null}
})
$modelsButton.Add_Click({
    $ptr=[IntPtr]::Zero
    try {
        $uri=$null
        if(![uri]::TryCreate($baseBox.Text.Trim(),[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment){throw '请填写有效 HTTPS 基础地址。'}
        $secret=$keyBox.Text.Trim()
        if(!$secret){
            $p=@($script:ProfileStore.profiles|Where-Object {$_.id -eq $idBox.Text})|Select-Object -First 1
            if(!$p){throw '请填写 API Key。'}
            $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR((ConvertTo-SecureString $p.credential))
            $secret=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        }
        $response=Invoke-RestMethod -Uri ($baseBox.Text.TrimEnd('/')+'/models') -Headers @{Authorization=('Bearer '+$secret)} -TimeoutSec 20
        $models=@($response.data|ForEach-Object {$_.id}|Where-Object {$_})
        if(!$models.Count){throw '接口未返回 data[].id；请手动填写模型列表。'}
        $modelBox.Text=$models -join ', ';$status.Text='模型列表已读取，保存或切换后生效；这不代表已验证 Responses 推理。'
    } catch {Write-Diagnostic ERROR 'Model list request failed (response body omitted to protect credentials)';[Windows.Forms.MessageBox]::Show('获取失败，请检查地址、密钥和 /models 支持情况，或手动填写模型。','获取模型失败')|Out-Null}
    finally {if($ptr -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)};$secret=$null}
})
$configBox.Add_Leave({Load-Settings})
function Run-Switch([string]$Mode) {
    $script:DiagnosticSecrets=@($keyBox.Text.Trim())
    try {
        foreach($c in @($officialButton,$deepseekButton,$newButton,$saveButton,$modelsButton,$profileBox)){$c.Enabled=$false}
        $draft=($script:ProfileStore|ConvertTo-Json -Depth 30|ConvertFrom-Json)
        $id='openai'
        if($Mode -ne 'openai'){$p=Read-ProfileEditor;Set-ProviderProfile $draft $p;$id=$p.id}
        $message=Switch-ProviderProfile $configBox.Text $draft $id -MigrateChats:$migrateBox.Checked -OfficialModel $modelBox.Text.Trim()
        $keyBox.Clear();Load-Settings
        [Windows.Forms.MessageBox]::Show($message,'切换完成')|Out-Null
    } catch {Write-Diagnostic ERROR ($_.Exception.ToString()+"`n"+$_.ScriptStackTrace);[Windows.Forms.MessageBox]::Show(($_.Exception.Message+"`r`n日志："+$script:DiagnosticLog),'没有完成切换')|Out-Null}
    finally {foreach($c in @($officialButton,$deepseekButton,$newButton,$saveButton,$modelsButton,$profileBox)){$c.Enabled=$true};$script:DiagnosticSecrets=@()}
}
$officialButton.Add_Click({Run-Switch 'openai'})
$deepseekButton.Add_Click({Run-Switch 'profile'})
Load-Settings

$script:MonitorForm=$null; $script:MonitorBox=$null; $script:MonitorTimer=$null
$script:MonitorState=$null; $script:MonitorToggle=$null; $script:MonitorLogPath=$null
$script:MonitorFullBox=$null; $script:MonitorPaused=$false; $script:MonitorFull=$false; $script:MonitorLastId=''
function Get-MonitorRoot {
    return [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($configBox.Text))
}
function Update-Monitor {
    param([switch]$Force)
    if (!$script:MonitorBox -or $script:MonitorBox.IsDisposed) { return }
    try {
        $root = Get-MonitorRoot
        $snapshot = Get-ProviderSnapshot -CodexRoot $root -Recent 6 -Full:$script:MonitorFull
        if ($snapshot.LastId -and ($Force -or $snapshot.LastId -ne $script:MonitorLastId)) {
            Add-ProviderWatchLog $root $snapshot
            $script:MonitorLastId = $snapshot.LastId
        }
        $script:MonitorBox.Text = ($snapshot.Lines -join "`r`n")
        $script:MonitorLogPath = Join-Path (Join-Path $root 'codex-switcher') 'provider-watch.log'
        $state = '最后刷新 ' + (Get-Date -Format 'HH:mm:ss') + '   ' + $snapshot.Headline
        if ($script:MonitorPaused) { $state = '[已暂停] ' + $state }
        $script:MonitorState.Text = $state
    } catch {
        Write-Diagnostic 'ERROR' ($_.Exception.ToString() + "`n" + $_.ScriptStackTrace)
        $script:MonitorBox.Text = '刷新失败：' + $_.Exception.Message
        $script:MonitorState.Text = '刷新失败'
    }
}
function Show-Monitor {
    if ($script:MonitorForm -and !$script:MonitorForm.IsDisposed) {
        $script:MonitorForm.Activate()
        Update-Monitor
        return
    }
    $script:MonitorBox = New-Object Windows.Forms.TextBox
    $script:MonitorBox.Multiline=$true; $script:MonitorBox.ReadOnly=$true
    $script:MonitorBox.WordWrap=$false; $script:MonitorBox.ScrollBars='Both'
    $script:MonitorBox.Dock='Fill'
    $script:MonitorBox.Font=New-Object Drawing.Font('Consolas',9.5)
    $script:MonitorBox.BackColor=[Drawing.Color]::White
    $panel=New-Object Windows.Forms.Panel
    $panel.Dock='Bottom'; $panel.Height=46
    $script:MonitorState=New-Object Windows.Forms.Label
    $script:MonitorState.SetBounds(10,12,420,22)
    $script:MonitorState.Text='准备中…'
    $script:MonitorFullBox=New-Object Windows.Forms.CheckBox
    $script:MonitorFullBox.Text='完整时间线（较慢）'; $script:MonitorFullBox.SetBounds(436,12,130,22)
    $script:MonitorFullBox.Add_CheckedChanged({
        $script:MonitorFull = $script:MonitorFullBox.Checked
        Update-Monitor
    })
    $refreshButton=New-Object Windows.Forms.Button
    $refreshButton.Text='立即刷新'; $refreshButton.SetBounds(572,8,96,30)
    $refreshButton.Add_Click({ Update-Monitor -Force })
    $script:MonitorToggle=New-Object Windows.Forms.Button
    $script:MonitorToggle.Text='暂停监测'; $script:MonitorToggle.SetBounds(674,8,104,30)
    $script:MonitorToggle.Add_Click({
        $script:MonitorPaused = !$script:MonitorPaused
        if ($script:MonitorPaused) { $script:MonitorToggle.Text='继续监测' } else { $script:MonitorToggle.Text='暂停监测' }
        Update-Monitor
    })
    $logButton=New-Object Windows.Forms.Button
    $logButton.Text='打开监测日志'; $logButton.SetBounds(784,8,110,30)
    $logButton.Add_Click({
        if ($script:MonitorLogPath -and (Test-Path -LiteralPath $script:MonitorLogPath)) {
            Start-Process -FilePath $script:MonitorLogPath
        } else {
            [Windows.Forms.MessageBox]::Show('还没有日志。先让 Codex 产生一次对话，再点“立即刷新”。','请求去向监测','OK','Information') | Out-Null
        }
    })
    $panel.Controls.AddRange(@($script:MonitorState,$script:MonitorFullBox,$refreshButton,$script:MonitorToggle,$logButton))
    $script:MonitorForm=New-Object Windows.Forms.Form
    $script:MonitorForm.Text='请求去向监测 — 谁在回答这个对话（只读）'
    $script:MonitorForm.ClientSize=New-Object Drawing.Size(906,600)
    $script:MonitorForm.StartPosition='CenterScreen'
    $script:MonitorForm.MinimumSize=New-Object Drawing.Size(700,400)
    $script:MonitorForm.Font=New-Object Drawing.Font('Microsoft YaHei UI',9)
    $script:MonitorForm.Controls.AddRange(@($script:MonitorBox,$panel))
    $script:MonitorTimer=New-Object Windows.Forms.Timer
    $script:MonitorTimer.Interval=3000
    $script:MonitorTimer.Add_Tick({ if (!$script:MonitorPaused) { Update-Monitor } })
    $script:MonitorForm.Add_FormClosed({
        if ($script:MonitorTimer) { $script:MonitorTimer.Stop(); $script:MonitorTimer.Dispose(); $script:MonitorTimer=$null }
        $script:MonitorForm=$null; $script:MonitorBox=$null
    })
    $script:MonitorForm.Show($form)
    $script:MonitorTimer.Start()
    Update-Monitor
}

if ($UiSmoke) {
    $smokeRoot = Join-Path ([IO.Path]::GetTempPath()) ('switcher-uismoke-' + [guid]::NewGuid().ToString('N'))
    $smokeSessions = Join-Path $smokeRoot 'sessions\2026\10\16'
    $null = New-Item -ItemType Directory -Path $smokeSessions -Force
    $smokeConfig = Join-Path $smokeRoot 'config.toml'
    Atomic-Write $smokeConfig "model = `"deepseek-v4-flash`"`r`nmodel_provider = `"deepseek`"`r`n[model_providers.deepseek]`r`nbase_url = `"https://api.deepseek.com`"`r`nwire_api = `"responses`"`r`n"
    $smokeLines = @(
        '{"timestamp":"2026-10-16T09:00:00Z","type":"session_meta","payload":{"id":"01a1smoke","session_id":"01a1smoke","model_provider":"deepseek"}}',
        '{"timestamp":"2026-10-16T09:01:00Z","type":"token_usage_record","payload":{"thread_id":"01a1smoke","response_id":"resp_0f3d8267cc5b1a5c016ad0ab9693a8819985dc69670901d255"}}',
        '{"timestamp":"2026-10-16T09:02:00Z","type":"token_usage_record","payload":{"thread_id":"01a1smoke","response_id":"8ca4c701-e67e-45ef-9e08-c40abadf3a56"}}'
    )
    [IO.File]::WriteAllText((Join-Path $smokeSessions 'rollout-01a1smoke.jsonl'), (($smokeLines -join "`r`n") + "`r`n"), $script:Utf8)
    $configBox.Text = $smokeConfig
    if ($form.Controls.Count -lt 25 -or !$profileBox -or !$saveButton) { throw 'UI validation failed' }
    if (!$progress) { throw 'progress bar missing from the switch form' }
    $script:ProfileStore=Get-ProfileStore $smokeConfig
    $smokeProfile=New-ProviderProfile smoke 'Smoke Vendor' https://example.invalid/v1 'model-one,model-two' 'dummy-smoke-key' '' $null
    Set-ProviderProfile $script:ProfileStore $smokeProfile
    Save-ProfileStore $smokeConfig $script:ProfileStore
    Refresh-ProfileList smoke
    if($baseBox.Text -ne 'https://example.invalid/v1' -or $modelBox.Text -notmatch 'model-two' -or $keyBox.Text){throw 'Profile selection did not populate editor safely'}
    Show-Monitor
    if (!$script:MonitorForm -or !$script:MonitorBox) { throw 'monitor window failed to open' }
    $monitorText = $script:MonitorBox.Text
    if ($monitorText -notmatch 'OpenAI官方\(resp_\)') { throw ('monitor missed official fingerprint: ' + $monitorText) }
    if ($monitorText -notmatch 'UUID') { throw ('monitor missed third-party fingerprint: ' + $monitorText) }
    if ($monitorText -notmatch '创建时模型') { throw ('monitor missed origin model: ' + $monitorText) }
    if ($monitorText -match '完整时间线') { throw 'monitor full timeline should be off by default' }
    $script:MonitorFullBox.Checked = $true
    Update-Monitor -Force
    $monitorText = $script:MonitorBox.Text
    if ($monitorText -notmatch '完整时间线') { throw ('monitor missed timeline when enabled: ' + $monitorText) }
    $smokeLog = Join-Path $smokeRoot 'codex-switcher\provider-watch.log'
    if (!(Test-Path -LiteralPath $smokeLog)) { throw 'monitor did not write the watch log' }
    $logText = [IO.File]::ReadAllText($smokeLog)
    if ($logText -notmatch '8ca4c701-e67e-45ef-9e08-c40abadf3a56') { throw ('watch log missing response id: ' + $logText) }
    if ($logText -notmatch 'provider=deepseek') { throw ('watch log missing provider: ' + $logText) }
    $monitorChars = $monitorText.Length
    $script:MonitorTimer.Stop()
    $script:MonitorForm.Dispose()
    Write-Output ('UI smoke PASS; controls=' + $form.Controls.Count + '; monitorChars=' + $monitorChars)
    $form.Dispose()
    # 自测用的临时目录不要留在 %TEMP% 里
    try { Remove-Item -LiteralPath $smokeRoot -Recurse -Force } catch { }
    return
}
Write-Diagnostic 'INFO' 'UI started'
try { [Windows.Forms.Application]::Run($form) } catch { Write-Diagnostic 'ERROR' ($_.Exception.ToString() + "`n" + $_.ScriptStackTrace); throw }
finally { Write-Diagnostic 'INFO' 'UI stopped' }
$form.Dispose()
