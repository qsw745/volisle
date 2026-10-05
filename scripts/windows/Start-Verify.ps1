# SPDX-License-Identifier: GPL-2.0-only
param([ValidatePattern('^[A-Za-z]:?$')][string]$Drive)
$ErrorActionPreference = 'Stop'
$reportDir = $null
try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw '此入口只在 Windows 上运行。' }
    . (Join-Path $PSScriptRoot 'Checksum.ps1')
    if (-not $Drive) { $Drive = Read-Host '请输入 qsw 硬盘盘符，例如 E（不要输入 C）' }
    if ($Drive -notmatch '^[A-Za-z]:?$') { throw '盘符格式不正确。' }
    $letter = $Drive.Substring(0,1).ToUpperInvariant()
    $root = $letter + ':\'
    if ($root -eq [IO.Path]::GetPathRoot($env:SystemRoot)) { throw '拒绝系统盘。' }
    $volume = Get-Volume -DriveLetter $letter -ErrorAction Stop
    if ($volume.FileSystem -ne 'NTFS') { throw '所选卷不是 NTFS。' }
    $manifestPath = Join-Path $PSScriptRoot 'checksums.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.schema_version -ne 1 -or $manifest.directory -notmatch '^Volisle-Acceptance-[0-9]{8}-[0-9a-f]{32}$') { throw '验收目录记录无效。' }
    $base = Join-Path $root $manifest.directory
    # Logs stay on the Windows user profile disk, never the tested volume.
    $reports = Join-Path $env:USERPROFILE 'Volisle-Windows-Reports'
    if ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($reports)) -eq $root) { throw '结果目录不能位于被测盘。' }
    $reportDir = Join-Path $reports ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $reportDir
    Write-Host ('正在只读校验：' + $base)
    $result = Get-VolisleChecksums -BasePath $base -ManifestPath $manifestPath
    $report = [ordered]@{ created_at=(Get-Date).ToUniversalTime().ToString('o'); drive=$root; label=$volume.FileSystemLabel; file_system=$volume.FileSystem; volume_bytes=$volume.Size; test_directory=$manifest.directory; file_checks=$result; windows_version=[Environment]::OSVersion.VersionString; powershell_version=$PSVersionTable.PSVersion.ToString(); chkdsk_verified=$false; windows_to_mac_verified=$false; acl_preservation_verified=$false }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $reportDir 'windows-checksums.json') -Encoding UTF8
    foreach ($file in $result.files) { Write-Host ($file.status + '  ' + $file.path) }
    Write-Host ('结果：' + $result.passed_count + '/' + $result.expected_count + ' 内容一致。')
    Write-Host ('报告保存在：' + $reportDir)
    if (-not $result.success) { throw '有文件缺失、不可读或内容不一致，请保留报告，不要修复或覆盖。' }
    Write-Host '文件内容核对通过。这不等于文件系统、权限和双向读写全部通过。'
    Write-Host ('下一步在管理员 PowerShell 执行 chkdsk ' + $letter + ':，不加修复参数。具体保存结果命令见说明。')
    exit 0
} catch {
    Write-Host ('验收未通过：' + $_.Exception.Message) -ForegroundColor Red
    if ($reportDir) { $_.Exception.Message | Set-Content -LiteralPath (Join-Path $reportDir 'error.txt') -Encoding UTF8 }
    exit 1
}
