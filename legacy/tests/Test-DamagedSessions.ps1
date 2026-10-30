# 回归测试：会话目录里存在损坏 / 空的 rollout 文件时，切换仍然要能完成
#
# 背景（另一台机器的故障）：
#   C:\Users\Kuen\.codex\sessions\2026\10\06\rollout-2026-10-06T17-22-54-....jsonl
#   首行不是有效 JSON（空文件 / 写到一半崩溃 / 不是会话文件），旧版工具在预扫描时直接抛
#   “会话文件首行不是有效 JSON”，整次切换被中止，用户切不动。
# 修复后的行为：这类文件被跳过（原因写进切换结果与 switch.log），其它会话照常迁移，坏文件本身不动。
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

$script:Utf8NoBom = New-Object Text.UTF8Encoding($false)
function Write-Text([string]$Path,[string]$Text) {
    $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Path)) -Force
    [IO.File]::WriteAllText($Path,$Text,$script:Utf8NoBom)
}
function Get-Bytes([string]$Path) { return [IO.File]::ReadAllBytes($Path) }

$officialConfig = @(
    'notify = [ "C:\\tools\\notify.exe", "turn-ended" ]'
    ''
    '[mcp_servers.demo]'
    'command = "demo.exe"'
) -join "`r`n"

$script:WorkRoot = Join-Path ([IO.Path]::GetTempPath()) ('switcher-damaged-test-' + [guid]::NewGuid().ToString('N'))
$sessions = Join-Path $script:WorkRoot 'sessions\2026\10\06'
$null = New-Item -ItemType Directory -Path $sessions -Force
Write-Output ('临时目录：' + $script:WorkRoot)

# 一个健康的会话文件：首行 session_meta（官方 provider）+ 一行 turn_context
$healthyFirst = '{"timestamp":"2026-10-06T09:22:54.000Z","ordinal":0,"type":"session_meta","payload":{"session_id":"01a11085-ebe0-7b33-9c0c-e82f00000001","id":"01a11085-ebe0-7b33-9c0c-e82f00000001","timestamp":"2026-10-06T09:22:54.000Z","cwd":"C:\\\\work","originator":"Codex Desktop","model_provider":"openai","base_instructions":{"text":"You are Codex."}}}'
$healthyTurn = '{"timestamp":"2026-10-06T09:23:00.000Z","ordinal":1,"type":"turn_context","payload":{"turn_id":"t1","cwd":"C:\\\\work","model":"gpt-5.6-sol","effort":"medium"}}'
$healthyPath = Join-Path $sessions 'rollout-2026-10-06T17-22-54-01a11085-healthy.jsonl'
Write-Text $healthyPath (($healthyFirst, $healthyTurn) -join "`r`n")

# 四种坏文件：空、截断、首行不是会话记录、首行缺 provider
$emptyPath = Join-Path $sessions 'rollout-2026-10-06T17-22-54-01a11085-empty.jsonl'
[IO.File]::WriteAllBytes($emptyPath, (New-Object byte[] 0))
$truncatedPath = Join-Path $sessions 'rollout-2026-10-06T17-22-54-01a11085-truncated.jsonl'
Write-Text $truncatedPath '{"timestamp":"2026-10-06T09:22:54.000Z","ordinal":0,"type":"session_meta","payload":{"session_id":"01a11085-ebe0-7b33-9c0c-e82f00000002","model_provider":"openai","base_instructions":{"text":"You are Co'
$noSessionPath = Join-Path $sessions 'rollout-2026-10-06T17-22-54-01a11085-nosession.jsonl'
Write-Text $noSessionPath '{"timestamp":"2026-10-06T09:22:54.000Z","type":"token_usage_record","payload":{"thread_id":"x","response_id":"resp_abc"}}'
$noProviderPath = Join-Path $sessions 'rollout-2026-10-06T17-22-54-01a11085-noprovider.jsonl'
Write-Text $noProviderPath '{"timestamp":"2026-10-06T09:22:54.000Z","type":"session_meta","payload":{"id":"01a11085-ebe0-7b33-9c0c-e82f00000003"}}'
# 首行正常、但最后一行写到一半（异常退出很常见）：预扫描放行，改写阶段必须跳过它而不是中止整次切换
$tailBrokenPath = Join-Path $sessions 'rollout-2026-10-06T17-22-54-01a11085-tailbroken.jsonl'
$tailBrokenFirst = '{"timestamp":"2026-10-06T09:22:54.000Z","ordinal":0,"type":"session_meta","payload":{"session_id":"01a11085-ebe0-7b33-9c0c-e82f00000004","id":"01a11085-ebe0-7b33-9c0c-e82f00000004","model_provider":"openai","base_instructions":{"text":"You are Codex."}}}'
Write-Text $tailBrokenPath ($tailBrokenFirst + "`r`n" + '{"timestamp":"2026-10-06T09:23:00.000Z","ordinal":1,"type":"turn_context","payload":{"turn_id":"t1","model":"gpt-5.6-so')

try {
    Write-Output ''
    Write-Output '1) 首行判定：能区分空文件、截断、非会话首行、缺 provider'
    $cases = @(
        @{ Path=$emptyPath;      Match='文件是空的' },
        @{ Path=$truncatedPath;  Match='首行不是有效 JSON' },
        @{ Path=$noSessionPath;  Match='首行不是 session_meta 记录（type=token_usage_record）' },
        @{ Path=$noProviderPath; Match='缺少 session_meta.model_provider' },
        @{ Path=$tailBrokenPath; Match='' },
        @{ Path=$healthyPath;    Match='' }
    )
    foreach ($case in $cases) {
        $session = Get-SessionHeader $case.Path
        if ($case.Match) { Assert-True ($session.Problem -match $case.Match) ((Split-Path $case.Path -Leaf) + ' -> ' + $session.Problem) }
        else { Assert-True ($session.Problem -eq '' -and $session.Header.payload.model_provider -eq 'openai') ((Split-Path $case.Path -Leaf) + ' 首行能正常解析') }
    }

    Write-Output ''
    Write-Output '2) 官方 -> deepseek：坏文件被跳过，健康会话照常迁移'
    Initialize-SqliteInterop
    $database = Join-Path $script:WorkRoot 'state_5.sqlite'
    [CodexSwitcherSqlite]::CreateEmptyStateDatabase($database)
    Assert-True (Test-Path -LiteralPath $database) '测试用 state 数据库创建成功'
    $configPath = Join-Path $script:WorkRoot 'config.toml'
    Write-Text $configPath $officialConfig
    $brokenPaths = @($emptyPath, $truncatedPath, $noSessionPath, $noProviderPath, $tailBrokenPath)
    $brokenBefore = @{}
    foreach ($p in $brokenPaths) { $brokenBefore[$p] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($p)) }
    $message = Switch-Mode $configPath 'deepseek' 'https://api.deepseek.com' 'deepseek-flash' 'sk-test' ''
    Assert-True ($message -match '跳过 5 个') '结果里报告跳过了 5 个坏文件'
    Assert-True ($message -match '文件是空的') '结果里说明空文件原因'
    Assert-True ($message -match '改写失败') '结果里说明最后一行损坏的文件是改写失败'
    Assert-True ($message -match '1 条会话索引') '数据库索引正常迁移'
    Assert-True (([IO.File]::ReadAllText($configPath)) -match '(?m)^model_provider = "deepseek"') '配置已切到 deepseek'
    $healthyAfter = [IO.File]::ReadAllText($healthyPath)
    Assert-True ($healthyAfter -match '"model_provider":"deepseek"') '健康会话被迁移到 deepseek'
    Assert-True ($healthyAfter -match '"model":"deepseek-flash"') '健康会话的模型被改写'
    foreach ($p in $brokenPaths) {
        $same = $brokenBefore[$p] -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($p))
        Assert-True $same ((Split-Path $p -Leaf) + ' 未被修改')
    }
    $logText = [IO.File]::ReadAllText((Join-Path $script:WorkRoot 'codex-switcher\switch.log'))
    Assert-True ($logText -match 'Skipped 5 unreadable session file') 'switch.log 记录了跳过的文件'

    Write-Output ''
    Write-Output '3) deepseek -> 官方：坏文件仍在也能完成切换'
    # 这个临时目录里没有官方模型线索，所以在“模型名称”栏里给一个官方模型名（工具第 2 种处理办法）
    $message = Switch-Mode $configPath 'openai' '' 'gpt-6.1-sol' '' ''
    Assert-True ($message -match '跳过 5 个') '反向切换同样只跳过坏文件'
    Assert-True ($message -match 'openai / gpt-6.1-sol') '反向切换成功并给出目标模型'
    Assert-True (([IO.File]::ReadAllText($healthyPath)) -match '"model_provider":"openai"') '健康会话切回官方 provider'

    Write-Output ''
    Write-Output ('结果：PASS ' + $script:Pass + '，FAIL ' + $script:Fail)
    if ($script:Fail -gt 0) { exit 1 }
} finally {
    if ($KeepTemp) { Write-Output ('保留临时目录：' + $script:WorkRoot) }
    elseif (Test-Path -LiteralPath $script:WorkRoot) { Remove-Item -LiteralPath $script:WorkRoot -Recurse -Force }
}
