# Read-only checksum verification; does not repair or modify the volume.
$ErrorActionPreference = 'Stop'
$base = [IO.Path]::GetFullPath($PSScriptRoot) + [IO.Path]::DirectorySeparatorChar
$manifest = Get-Content -LiteralPath (Join-Path $base 'checksums.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$count = 0
foreach ($entry in $manifest.files.PSObject.Properties) {
    $path = [IO.Path]::GetFullPath((Join-Path $base $entry.Name))
    if (-not $path.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid manifest path' }
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $entry.Value) { throw "Checksum mismatch: $($entry.Name)" }
    $count++
    Write-Host "PASS $($entry.Name)"
}
Write-Host "Verified $count files. No files were modified."
