# Local Windows 11 VM only, disposable reference-converted VHDs downloaded
# from the host. Does not create Windows 7 provenance or touch physical disks.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = 'C:\Windows\Temp\volisle-diffuser-20261107'
New-Item -ItemType Directory -Force $root | Out-Null
$hostBase = 'http://10.211.55.2:8767'
$expected = Invoke-RestMethod "$hostBase/expected.json"
$expectedCounts = @{}
foreach ($bits in @(128, 256)) {
    $name = "diffuser$bits"
    $files = @($expected.$name)
    if ($files.Count -ne 4) { throw "$name expected file manifest must contain four entries" }
    foreach ($file in $files) {
        if (-not $file.path -or $null -eq $file.size -or $file.size -lt 0 -or $file.sha256 -notmatch '^[0-9a-f]{64}$') {
            throw "$name malformed expected file manifest"
        }
    }
    $expectedCounts[$name] = $files.Count
}
$results = @()
foreach ($bits in @(128, 256)) {
    $name = "diffuser$bits"
    $path = "$root\$name.vhd"
    Invoke-WebRequest -UseBasicParsing "$hostBase/$name.vhd" -OutFile $path
    $meta = Invoke-RestMethod "$hostBase/$name.json"
    try {
        $image = Mount-DiskImage -ImagePath $path -PassThru
        $disk = $image | Get-Disk
        $partition = $disk | Get-Partition | Where-Object Type -ne 'Reserved' | Select-Object -First 1
        if (-not $partition.DriveLetter) {
            $partition | Add-PartitionAccessPath -AssignDriveLetter
            $partition = Get-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber
        }
        $drive = "$($partition.DriveLetter):"
        $secure = ConvertTo-SecureString $meta.password -AsPlainText -Force
        Unlock-BitLocker -MountPoint $drive -Password $secure -ErrorAction Stop | Out-Null
        $volume = Get-BitLockerVolume -MountPoint $drive
        if ([string]$volume.EncryptionMethod -ne "Aes${bits}Diffuser") { throw "$name unexpected encryption method" }
        foreach ($file in $expected.$name) {
            $target = "$drive\$($file.path.Replace('/', '\'))"
            $item = Get-Item -LiteralPath $target
            if ($item.Length -ne $file.size) { throw "$name file size mismatch" }
            $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLower()
            if ($hash -ne $file.sha256) { throw "$name file hash mismatch: $($file.path)" }
        }
        $text = "Windows diffuser $bits verified Mac writes`n"
        [IO.File]::WriteAllText("$drive\windows-roundtrip.txt", $text, [Text.UTF8Encoding]::new($false))
        $results += @{ name=$name; method=[string]$volume.EncryptionMethod; mac_files_verified=$true;
            mac_files_verified_count=$expectedCounts[$name];
            windows_file_sha256=(Get-FileHash "$drive\windows-roundtrip.txt" -Algorithm SHA256).Hash.ToLower() }
        "$name $($volume.EncryptionMethod): Mac files verified; Windows file written"
    } finally {
        Dismount-DiskImage -ImagePath $path -ErrorAction SilentlyContinue
    }
    Invoke-WebRequest -UseBasicParsing -Method Put -InFile $path -Uri "http://10.211.55.2:8766/$name.vhd" | Out-Null
}
$report = @{ platform='Windows 11 local Parallels VM'; provenance='reference-converted CBC fixtures; NOT Windows 7-created'; results=$results }
$json = $report | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText("$root\windows-result.json", $json, [Text.UTF8Encoding]::new($false))
Invoke-WebRequest -UseBasicParsing -Method Put -InFile "$root\windows-result.json" -Uri 'http://10.211.55.2:8766/windows-result.json' | Out-Null
