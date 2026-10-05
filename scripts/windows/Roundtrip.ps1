# Volisle Mac <-> Windows round trip (R5). Only touches <Drive>:\<Folder>.
# chkdsk runs WITHOUT /f (read-only scan). Never formats, repairs or deletes
# anything outside the test folder.
param(
    [Parameter(Mandatory)][ValidatePattern('^[D-Z]$')][string]$Drive,
    [Parameter(Mandatory)][ValidatePattern('^Volisle-Roundtrip-[0-9A-Za-z-]+$')][string]$Folder,
    [Parameter(Mandatory)][ValidateSet('VerifyMac', 'WindowsWrite', 'VerifyAfterMac', 'VerifyAcl2')][string]$Phase
)
$ErrorActionPreference = 'Stop'
$root = "${Drive}:\$Folder"
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Missing test folder $root" }
$report = [ordered]@{ phase = $Phase; drive = $Drive; checks = @(); ok = $false }

function Hash($path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Verify-Manifest($name) {
    $manifest = Get-Content -LiteralPath (Join-Path $root $name) -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($entry in $manifest.files.PSObject.Properties) {
        $path = [IO.Path]::GetFullPath((Join-Path $root $entry.Name))
        if (-not $path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid manifest path' }
        if ((Hash $path) -ne $entry.Value) { throw "Checksum mismatch: $($entry.Name)" }
    }
    $script:report.checks += "$name verified ($(@($manifest.files.PSObject.Properties).Count) files)"
}
function Scan-Volume {
    $dirty = (& fsutil dirty query "${Drive}:") -join ' '
    $out = & chkdsk "${Drive}:" 2>&1
    $script:report.dirty = $dirty
    $script:report.chkdskExit = $LASTEXITCODE
    $script:report.chkdskTail = ($out | Select-Object -Last 12) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "chkdsk (read-only) reported problems, exit $LASTEXITCODE" }
    $script:report.checks += 'chkdsk read-only clean'
}
function Save-Acl($file) {
    $target = Join-Path $root 'Win-ACL'
    & icacls $target /save (Join-Path $root $file) /t /c | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'icacls /save failed' }
}

switch ($Phase) {
    'VerifyMac' {
        Verify-Manifest 'mac-manifest.json'
        Scan-Volume
    }
    'WindowsWrite' {
        $acl = Join-Path $root 'Win-ACL'
        New-Item -ItemType Directory -Path $acl | Out-Null
        # Explicit, non-inherited ACL: owner full, Users read-only.
        & icacls $acl /inheritance:r /grant:r "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)RX" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'icacls grant failed' }
        Set-Content -LiteralPath (Join-Path $acl 'inherited.txt') -Value 'written by Windows, inherits Win-ACL' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'win-new.txt') -Value ('Windows 新建 ' + (Get-Date -Format o)) -Encoding UTF8
        Add-Content -LiteralPath (Join-Path $root 'mac-edit.txt') -Value 'Windows appended line' -Encoding UTF8
        Save-Acl 'acl-before.txt'
        $files = [ordered]@{}
        foreach ($name in @('Win-ACL\inherited.txt', 'win-new.txt', 'mac-edit.txt')) { $files[$name] = Hash (Join-Path $root $name) }
        @{ files = $files } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'windows-manifest.json') -Encoding UTF8
        $report.checks += 'windows files and explicit ACL created'
        Scan-Volume
    }
    'VerifyAfterMac' {
        Verify-Manifest 'mac-manifest-2.json'
        Save-Acl 'acl-after.txt'
        $before = Get-Content -LiteralPath (Join-Path $root 'acl-before.txt') -Encoding Unicode
        $after = Get-Content -LiteralPath (Join-Path $root 'acl-after.txt') -Encoding Unicode
        # Entries present before Mac editing must be unchanged afterwards.
        for ($i = 0; $i -lt $before.Count; $i += 2) {
            $j = [Array]::IndexOf($after, $before[$i])
            if ($j -lt 0 -or $after[$j + 1] -ne $before[$i + 1]) { throw "ACL changed for $($before[$i])" }
        }
        $report.checks += 'pre-existing ACLs preserved after Mac edit'
        $created = Join-Path $root 'Win-ACL\mac-created.txt'
        $parentAces = (Get-Acl -LiteralPath (Join-Path $root 'Win-ACL')).Access | Where-Object { $_.InheritanceFlags -ne 'None' } | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique
        $childAces = (Get-Acl -LiteralPath $created).Access | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique
        $report.macCreatedAces = $childAces
        if (Compare-Object $parentAces $childAces) { throw 'Mac-created file did not inherit the folder ACL' }
        $report.checks += 'Mac-created file inherits folder ACL'
        Scan-Volume
    }
    'VerifyAcl2' {
        $parent = (Get-Acl -LiteralPath (Join-Path $root 'Win-ACL')).Access | Where-Object { $_.InheritanceFlags -ne 'None' } | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique
        $report.acl = [ordered]@{}
        foreach ($name in @('Win-ACL\mac-created-2.txt', 'Win-ACL\mac-dir', 'Win-ACL\mac-dir\nested.txt', 'Win-ACL\inherited.txt')) {
            $aces = (Get-Acl -LiteralPath (Join-Path $root $name)).Access
            $ids = $aces | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique
            $report.acl[$name] = (& icacls (Join-Path $root $name)) -join ' '
            if (Compare-Object $parent $ids) { throw "$name does not carry the folder's inheritable ACL" }
            if ($aces | Where-Object { -not $_.IsInherited }) { throw "$name has non-inherited ACEs" }
        }
        $report.checks += 'Mac-created file/dir inherit; replaced file keeps its inherited ACL'
        Scan-Volume
    }
}
$report.ok = $true
$report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $root "windows-$Phase.json") -Encoding UTF8
$report | ConvertTo-Json -Depth 4
