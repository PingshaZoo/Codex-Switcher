# 回归测试：切回 OpenAI 官方登录
#
# 背景（本次故障）：官方登录的 config.toml 通常不写 model / model_provider（模型由服务器下发），
# 旧版工具因此把空的 officialRoot 存进 state.json，切回官方时报
# “找不到官方配置 / 保存的官方配置没有明确模型”，用户被困在第三方 provider 上。
#
# 覆盖内容：
#   1. 官方配置 -> deepseek -> 官方 往返后，官方配置内容完整还原（只多出工具自己的 provider 段）；
#   2. 官方配置没写 model 时，自动从本机 Codex 状态（.codex-global-state.json / models_cache.json）确定官方模型；
#   3. 自动识别不到时，可用“模型名称”栏指定官方模型；第三方模型名不会被当成官方模型；
#   4. 完全没有官方线索时：明确报错且不修改任何文件；
#   5. 生成的 config.toml 不允许出现重复顶层键（会让 Codex 启动失败）。
#
# 测试只操作 %TEMP% 下的临时目录，不读写真实 .codex。
param([switch]$KeepTemp)
$ErrorActionPreference = 'Stop'

$library = Join-Path (Split-Path -Parent $PSScriptRoot) 'Switcher.ps1'
if (!(Test-Path -LiteralPath $library -PathType Leaf)) { throw ('缺少共用组件：' + $library) }
. $library -LibraryOnly
function Assert-Closed { }   # 测试用：跳过“请先退出 Codex”检查（测试只动临时目录）

$script:Pass = 0
$script:Fail = 0
function Assert-True([bool]$Condition,[string]$Name) {
    if ($Condition) { $script:Pass++; Write-Output ('  [PASS] ' + $Name) }
    else { $script:Fail++; Write-Output ('  [FAIL] ' + $Name) }
}
function Assert-Equal($Expected,$Actual,[string]$Name) {
    if ([string]$Expected -eq [string]$Actual) { $script:Pass++; Write-Output ('  [PASS] ' + $Name) }
    else {
        $script:Fail++
        Write-Output ('  [FAIL] ' + $Name)
        Write-Output ('         期望：' + $Expected)
        Write-Output ('         实际：' + $Actual)
    }
}
function Assert-Throws([scriptblock]$Action,[string]$Match,[string]$Name) {
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    if (!$message) { $script:Fail++; Write-Output ('  [FAIL] ' + $Name + '（没有报错）'); return }
    if ($message -notmatch $Match) { $script:Fail++; Write-Output ('  [FAIL] ' + $Name + '（报错内容不符：' + $message + '）'); return }
    $script:Pass++
    Write-Output ('  [PASS] ' + $Name)
}

$script:ModeMarker = '(?ms)^# CODEX-SWITCHER-BEGIN\r?\n.*?^# CODEX-SWITCHER-END\r?\n?'
$script:Utf8NoBom = New-Object Text.UTF8Encoding($false)
function Write-Text([string]$Path,[string]$Text) {
    $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Path)) -Force
    [IO.File]::WriteAllText($Path,$Text,$script:Utf8NoBom)
}
function Get-Text([string]$Path) { return [IO.File]::ReadAllText($Path) }
function Get-Comparable([string]$Text) { return ([regex]::Replace($Text,$script:ModeMarker,'')).TrimEnd() }
function Get-Canonical([string]$Text) {
    # 可切换根键会被工具提到根区最前面，所以比较时把根键排序后再比，其余内容必须逐字一致。
    $clean = [regex]::Replace($Text,$script:ModeMarker,'')
    $split = Split-Config $clean
    $root = (@($split.Root) | Sort-Object) -join "`n"
    $rest = [regex]::Replace($split.Rest,'(\r?\n){2,}',"`n").Trim()
    return ($root + "`n" + '---' + "`n" + $rest)
}
function Get-State([string]$RootDir) { return ((Get-Text (Join-Path $RootDir 'codex-switcher\state.json')) | ConvertFrom-Json) }
function New-Home([string]$Name,[string]$Config,[string]$StateJson,[string]$CatalogJson,[string]$GlobalStateJson) {
    $fakeHome = Join-Path $script:WorkRoot $Name
    $null = New-Item -ItemType Directory -Path $fakeHome -Force
    Write-Text (Join-Path $fakeHome 'config.toml') $Config
    if ($StateJson) { Write-Text (Join-Path $fakeHome 'codex-switcher\state.json') $StateJson }
    if ($CatalogJson) { Write-Text (Join-Path $fakeHome 'models_cache.json') $CatalogJson }
    if ($GlobalStateJson) { Write-Text (Join-Path $fakeHome '.codex-global-state.json') $GlobalStateJson }
    return $fakeHome
}
function New-StateJson([string[]]$OfficialRoot,[string]$Mode,[string]$Model) {
    return (@{ officialRoot=@($OfficialRoot); mode=$Mode; apiBase='https://api.deepseek.com'; model=$Model; catalog=''; lastBackup='' } | ConvertTo-Json -Depth 6)
}

# 官方登录下最简的 config.toml：只有非托管根键加两个段落（用户机器上就是这样）
$officialNoModel = @(
    'web_search = "enabled"'
    'notify = [ "C:\\tools\\notify.exe", "turn-ended" ]'
    ''
    '[features]'
    'js_repl = false'
    ''
    '[mcp_servers.demo]'
    'command = "demo.exe"'
) -join "`r`n"
# 官方配置里显式写了 model 的情况
$officialWithModel = @(
    'model = "gpt-5.6-sol"'
    'model_reasoning_effort = "high"'
    'notify = [ "C:\\tools\\notify.exe", "turn-ended" ]'
    ''
    '[mcp_servers.demo]'
    'command = "demo.exe"'
) -join "`r`n"
# 第三方 provider 已经写进配置的机器（state.json 丢失时的场景）
$deepseekOnly = @(
    'model_provider = "deepseek"'
    'model = "deepseek-flash"'
    'model_reasoning_effort = "high"'
    'web_search = "disabled"'
    'notify = [ "C:\\tools\\notify.exe", "turn-ended" ]'
    ''
    '[mcp_servers.demo]'
    'command = "demo.exe"'
) -join "`r`n"
$officialCatalog = '{"fetched_at":"2026-10-16T13:14:48Z","models":[{"slug":"gpt-6.1-sol","priority":1},{"slug":"gpt-6-luna","priority":4},{"slug":"gpt-5.6-sol","priority":5}]}'
$officialGlobalState = '{"model-picker":{"eligible_codex_model_slugs":["gpt-6.1-sol","gpt-6-luna","gpt-5.6-sol"],"default_model_slug":"gpt-6.1-sol-wm","model_picker_version":2}}'

$script:WorkRoot = Join-Path ([IO.Path]::GetTempPath()) ('switcher-official-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $script:WorkRoot -Force
Write-Output ('临时目录：' + $script:WorkRoot)

try {
    Write-Output ''
    Write-Output '1) 官方配置（带 model）-> deepseek -> 官方：配置完整还原'
    $fakeHome = New-Home 'roundtrip' $officialWithModel '' '' ''
    $configPath = Join-Path $fakeHome 'config.toml'
    $before = Get-Text $configPath
    $deepseekMessage = Switch-Mode $configPath 'deepseek' 'https://api.deepseek.com' 'deepseek-flash' 'sk-test' ''
    $deepseekText = Get-Text $configPath
    Assert-True ($deepseekText -match '(?m)^model_provider = "deepseek"') '切到 deepseek 后写入 provider'
    Assert-True ($deepseekText -match '(?m)^model = "deepseek-flash"') '切到 deepseek 后写入模型'
    Assert-True ($deepseekText -notmatch 'gpt-5.6-sol') '官方模型已从配置中移除'
    Assert-Equal 'gpt-5.6-sol' (Get-State $fakeHome).officialModel 'state 记录官方模型'
    Assert-True ($deepseekMessage -match 'deepseek-flash') 'deepseek 结果消息含目标模型'
    $officialMessage = Switch-Mode $configPath 'openai' '' '' '' ''
    Assert-Equal (Get-Comparable $before) (Get-Comparable (Get-Text $configPath)) '切回官方后配置逐字还原'
    Assert-True ((Get-Text $configPath) -match 'CODEX-SWITCHER-BEGIN') '保留 DeepSeek provider 段（旧会话仍可续聊）'
    Assert-True ($officialMessage -match 'openai / gpt-5.6-sol') '切回官方使用保存的官方模型'
    Assert-Equal 'openai' (Get-State $fakeHome).mode 'state.mode 变为 openai'

    Write-Output ''
    Write-Output '2) 官方配置没写 model（本次故障场景）：自动取应用当前官方模型'
    $fakeHome = New-Home 'no-model' $officialNoModel '' $officialCatalog $officialGlobalState
    $configPath = Join-Path $fakeHome 'config.toml'
    $officialBefore = Get-Text $configPath
    Switch-Mode $configPath 'deepseek' 'https://api.deepseek.com' 'deepseek-flash' 'sk-test' '' | Out-Null
    $state = Get-State $fakeHome
    Assert-Equal 'gpt-6.1-sol' $state.officialModel '切走官方时记住官方模型（去掉 -wm 后缀）'
    Assert-Equal 0 (@(@($state.officialRoot) | Where-Object { $_ -match '^model\s*=' }).Count) '官方配置没有记下 model'
    $message = Switch-Mode $configPath 'openai' '' '' '' ''
    $text = Get-Text $configPath
    Assert-True ($message -match 'openai / gpt-6.1-sol') '切回官方成功并选对官方模型'
    Assert-True ($text -notmatch '(?m)^model\s*=') '官方配置不再写 model'
    Assert-True ($text -notmatch '(?m)^model_provider\s*=') '官方配置不再写 model_provider'
    Assert-True ($text -notmatch '(?m)^model_catalog_json\s*=') '官方配置不再写 model_catalog_json'
    Assert-True ($text -match '(?m)^web_search = "enabled"') '还原官方配置里的 web_search'
    Assert-True ($text -match 'notify = ') '原有 notify 根键保留'
    Assert-True ($text -match 'mcp_servers\.demo') '原有段落保留'
    Assert-Equal (Get-Canonical $officialBefore) (Get-Canonical $text) '还原后的官方配置与切换前等价'

    Write-Output ''
    Write-Output '3) 反复切换不会写出重复顶层键'
    Switch-Mode $configPath 'deepseek' 'https://api.deepseek.com' 'deepseek-flash' '' '' | Out-Null
    $text = Get-Text $configPath
    Assert-Equal 0 (@(Get-DuplicateRootKeys $text)).Count '再切 deepseek 后没有重复顶层键'
    Assert-Equal 1 ([regex]::Matches($text,'(?m)^web_search\s*=').Count) 'web_search 只出现一次'
    Assert-True ($text -match '(?m)^model = "deepseek-flash"') '沿用已保存密钥完成第二次切换'

    Write-Output ''
    Write-Output '4) 识别不到官方模型时：可用“模型名称”栏指定；第三方名字不会被采纳'
    $stateJson = New-StateJson @() 'deepseek' 'deepseek-flash'
    $twoModelGlobalState = '{"model-picker":{"eligible_codex_model_slugs":["gpt-6-luna","gpt-5.6-sol"]}}'
    # 自动识别只会挑到 gpt-6-luna，所以这里能验证“栏里填写的模型优先”
    $fakeHome = New-Home 'manual-model' $officialNoModel $stateJson $officialCatalog $twoModelGlobalState
    $configPath = Join-Path $fakeHome 'config.toml'
    # 参数顺序：配置文件, 模式, 接口地址, 模型, Key, 目录 —— 切官方时模型填在第 4 个参数
    $message = Switch-Mode $configPath 'openai' '' 'gpt-5.6-sol' '' ''
    Assert-True ($message -match 'openai / gpt-5.6-sol') '用栏里填写的官方模型切换'
    Assert-Equal 'gpt-5.6-sol' (Get-State $fakeHome).officialModel 'state 记录栏里填写的官方模型'
    # 填第三方模型名时：忽略它，退回自动识别的官方模型，绝不把旧会话迁到第三方模型
    $fakeHome = New-Home 'bad-model' $officialNoModel $stateJson $officialCatalog $twoModelGlobalState
    $configPath = Join-Path $fakeHome 'config.toml'
    $message = Switch-Mode $configPath 'openai' '' 'deepseek-flash' '' ''
    Assert-True ($message -match 'openai / gpt-6-luna') '第三方模型名被忽略，改用官方模型'
    Assert-True ($message -notmatch 'openai / deepseek-flash') '旧会话不会被迁到第三方模型'
    Assert-True ((Get-Text $configPath) -notmatch 'deepseek-flash') '官方配置里不残留第三方模型名'

    Write-Output ''
    Write-Output '5) 完全没有官方线索时：报错且不改文件'
    $fakeHome = New-Home 'no-hint' $officialNoModel $stateJson '' ''
    $configPath = Join-Path $fakeHome 'config.toml'
    $before = Get-Text $configPath
    Assert-Throws { Switch-Mode $configPath 'openai' '' '' '' '' } '无法确定官方模式' '没有官方模型线索时明确报错'
    Assert-Equal $before (Get-Text $configPath) '报错时配置文件保持不变'

    Write-Output ''
    Write-Output '6) 缺少 state.json 时的提示与“已是官方配置”的短路'
    $fakeHome = New-Home 'no-state' $deepseekOnly '' '' ''
    Assert-Throws { Switch-Mode (Join-Path $fakeHome 'config.toml') 'openai' '' '' '' '' } '未找到本工具保存的官方配置' '缺少 state.json 时提示原因和处理办法'
    $fakeHome = New-Home 'already-official' $officialNoModel '' '' ''
    Assert-Equal '当前已经是官方配置，无需修改。' (Switch-Mode (Join-Path $fakeHome 'config.toml') 'openai' '' '' '' '') '已是官方配置时直接返回'

    Write-Output ''
    Write-Output '7) 相关纯函数'
    $duplicateSample = 'model = "a"' + "`r`n" + 'model = "b"' + "`r`n" + '[s]' + "`r`n"
    Assert-Equal 'model' ((Get-DuplicateRootKeys $duplicateSample) -join ',') '能发现重复顶层键'
    $managedSample = 'web_search = "disabled"' + "`r`n" + 'model = "x"' + "`r`n" + '[s]' + "`r`n"
    Assert-Equal 2 (@(Split-Config $managedSample).Root.Count) 'web_search 与 model 都按可切换根键处理'
    $made = Make-Config ('notify = 1' + "`r`n" + "`r`n" + '[s]' + "`r`n") @() 'BLOCK'
    Assert-True (!$made.StartsWith("`r`n")) '目标根键为空时不会写出空行'
    Assert-True (-not (Test-OfficialModelName $script:WorkRoot '任何名字')) '没有证据时不认可任何模型名'

    Write-Output ''
    Write-Output ('结果：PASS ' + $script:Pass + '，FAIL ' + $script:Fail)
    if ($script:Fail -gt 0) { exit 1 }
} finally {
    if ($KeepTemp) { Write-Output ('保留临时目录：' + $script:WorkRoot) }
    elseif (Test-Path -LiteralPath $script:WorkRoot) { Remove-Item -LiteralPath $script:WorkRoot -Recurse -Force }
}
