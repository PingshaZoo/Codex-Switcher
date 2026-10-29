param(
    [string]$CodexRoot = (Join-Path $env:USERPROFILE '.codex'),
    [switch]$ScanAll,
    [int]$Recent = 8
)
$ErrorActionPreference = 'Stop'
$library = Join-Path $PSScriptRoot 'Switcher.ps1'
if (!(Test-Path -LiteralPath $library -PathType Leaf)) { throw ('缺少共用组件 Switcher.ps1：' + $library) }
. $library -LibraryOnly

$root = [IO.Path]::GetFullPath($CodexRoot)

if ($ScanAll) {
    $files = @(Get-CheckRolloutFiles $root)
    Write-Output '============================================================='
    Write-Output ' 全部会话请求去向一览（只读，不修改任何文件）'
    Write-Output '============================================================='
    Write-Output ('会话目录：' + $root)
    Write-Output ('共 ' + $files.Count + ' 个会话文件')
    Write-Output ''
    if ($files.Count -eq 0) { return }
    $rows = New-Object 'Collections.Generic.List[object]'
    foreach ($file in @($files | Sort-Object LastWriteTime)) {
        $entries = @(Read-CheckResponseIds $file.FullName 0 0)
        if ($entries.Count -eq 0) { continue }
        $header = Get-CheckHeader $file.FullName
        $origin = if ($header -and $header.base_instructions -and $header.base_instructions.provenance -and $header.base_instructions.provenance.model) { [string]$header.base_instructions.provenance.model } else { '（未记录）' }
        $counts = @{}
        foreach ($entry in $entries) {
            $key = Get-CheckFingerprint $entry.Id
            if (!$counts.ContainsKey($key)) { $counts[$key] = 0 }
            $counts[$key]++
        }
        $parts = New-Object 'Collections.Generic.List[string]'
        foreach ($key in @($counts.Keys)) { $parts.Add($key + ' x ' + $counts[$key]) }
        $rows.Add([pscustomobject]@{
            When   = $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
            Id     = if ($header) { [string]$header.id } else { '?' }
            Origin = $origin
            Last   = (Get-CheckFingerprint $entries[$entries.Count - 1].Id)
            Mix    = ($parts.ToArray() -join '  +  ')
        })
    }
    $rows | Format-Table -AutoSize | Out-String -Width 220 | Write-Output
    Write-Output 'Origin = 会话创建时的模型，取自会话头，切换工具不会修改，可交叉验证。'
    Write-Output 'Last   = 该会话最近一次请求由谁签发。'
    Write-Output '提示：要让某个会话显示真正 OpenAI 官方格式，需要该会话在官方模式下产生过新的回合。'
    return
}

$snapshot = Get-ProviderSnapshot -CodexRoot $root -Recent $Recent -Full
Write-Output '============================================================='
Write-Output ' Codex 请求去向自查（只读，不修改任何文件）'
Write-Output '============================================================='
foreach ($line in $snapshot.Lines) { Write-Output $line }
Write-Output '============================================================='
if ($snapshot.LastId) {
    Write-Output ('一句话结论：' + $snapshot.Conclusion)
}
