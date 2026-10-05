$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows/Checksum.ps1')
$base = Join-Path ([IO.Path]::GetTempPath()) ('volisle-windows-unit-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($base) | Out-Null
try {
    $data = Join-Path $base 'data'
    [IO.Directory]::CreateDirectory($data) | Out-Null
    $file = Join-Path $data '中文 空格.txt'
    [IO.File]::WriteAllText($file, 'known bytes', [Text.UTF8Encoding]::new($false))
    $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest = Join-Path $base 'checksums.json'
    @{ files = @{ '中文 空格.txt' = $hash } } | ConvertTo-Json | Set-Content -LiteralPath $manifest -Encoding UTF8
    $r = Get-VolisleChecksums -BasePath $data -ManifestPath $manifest
    if (-not $r.success -or $r.checked_count -ne 1) { throw 'Correct file rejected' }
    [IO.File]::WriteAllText($file, 'changed')
    $r = Get-VolisleChecksums -BasePath $data -ManifestPath $manifest
    if ($r.success -or $r.files[0].status -ne 'mismatch') { throw 'Changed content accepted' }
    Remove-Item -LiteralPath $file
    $r = Get-VolisleChecksums -BasePath $data -ManifestPath $manifest
    if ($r.success -or $r.files[0].status -ne 'unreadable') { throw 'Missing file accepted' }
    foreach ($name in @('../outside', '/absolute', 'C:/escape', 'a/../b', 'a//b', 'a\b', 'a:stream')) {
        @{ files = @{ $name = $hash } } | ConvertTo-Json | Set-Content -LiteralPath $manifest -Encoding UTF8
        $rejected = $false
        try { $null = Get-VolisleChecksums -BasePath $data -ManifestPath $manifest } catch { $rejected = $true }
        if (-not $rejected) { throw ('Unsafe name accepted: ' + $name) }
    }
    foreach ($files in @(@{}, @{ 'valid.txt' = 'not-a-hash' })) {
        @{ files = $files } | ConvertTo-Json | Set-Content -LiteralPath $manifest -Encoding UTF8
        $rejected = $false
        try { $null = Get-VolisleChecksums -BasePath $data -ManifestPath $manifest } catch { $rejected = $true }
        if (-not $rejected) { throw 'Invalid manifest accepted' }
    }
    # A link to readable data must not be followed outside the test tree.
    $outside = Join-Path $base 'outside.txt'
    [IO.File]::WriteAllText($outside, 'known bytes', [Text.UTF8Encoding]::new($false))
    $null = New-Item -ItemType SymbolicLink -Path $file -Target $outside
    @{ files = @{ '中文 空格.txt' = $hash } } | ConvertTo-Json | Set-Content -LiteralPath $manifest -Encoding UTF8
    $r = Get-VolisleChecksums -BasePath $data -ManifestPath $manifest
    if ($r.success -or $r.files[0].status -ne 'unreadable') { throw 'Symlink followed' }
    Write-Host '13 checksum checks passed: valid, mismatch, missing, 7 path escapes, empty, invalid hash, symlink.'
} finally { Remove-Item -LiteralPath $base -Recurse -Force }
