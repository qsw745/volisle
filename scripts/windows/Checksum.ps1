# SPDX-License-Identifier: GPL-2.0-only
# Read only the listed unnamed file contents; never follows reparse points.
function Get-VolisleChecksums {
    param([Parameter(Mandatory=$true)][string]$BasePath,
          [Parameter(Mandatory=$true)][string]$ManifestPath)
    $base = [IO.Path]::GetFullPath($BasePath)
    $baseItem = Get-Item -LiteralPath $base -Force -ErrorAction Stop
    if (-not $baseItem.PSIsContainer -or ($baseItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Invalid test directory' }
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $manifest.files -or $manifest.files -isnot [pscustomobject]) { throw 'Invalid files manifest' }
    $entries = @($manifest.files.PSObject.Properties)
    if ($entries.Count -eq 0 -or $entries.Count -gt 1000) { throw 'Empty or oversized manifest' }
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    # Validate the entire manifest before opening any payload.
    foreach ($entry in $entries) {
        if ([string]::IsNullOrEmpty($entry.Name) -or $entry.Name -match '[:\\]' -or
            $entry.Value -isnot [string] -or $entry.Value -cnotmatch '^[0-9a-f]{64}$' -or -not $names.Add($entry.Name)) { throw 'Invalid manifest entry' }
        foreach ($part in $entry.Name.Split('/')) {
            if ($part -eq '' -or $part -eq '.' -or $part -eq '..' -or $part -match '[. ]$' -or $part -match '[<>"|?*\x00-\x1f]' -or $part -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)') { throw 'Invalid manifest path' }
        }
    }
    $results = @()
    foreach ($entry in $entries) {
        $actual = $null; $reason = $null; $status = 'unreadable'; $length = $null
        try {
            $path = $base
            foreach ($part in $entry.Name.Split('/')) {
                $path = Join-Path $path $part
                $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse point rejected' }
            }
            if ($item.PSIsContainer) { throw 'Expected a regular file' }
            $length = $item.Length
            $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
            $status = if ($actual -eq $entry.Value) { 'pass' } else { 'mismatch' }
        } catch { $reason = $_.Exception.Message }
        $results += [pscustomobject]@{ path=$entry.Name; expected_sha256=$entry.Value; actual_sha256=$actual; bytes=$length; status=$status; error=$reason }
    }
    $passed = @($results | Where-Object { $_.status -eq 'pass' }).Count
    return [pscustomobject]@{ schema_version=1; success=($passed -eq $entries.Count); expected_count=$entries.Count; checked_count=$results.Count; passed_count=$passed; files=$results }
}
