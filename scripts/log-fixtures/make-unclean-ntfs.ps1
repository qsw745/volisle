# Runs inside the Parallels "Windows 11" VM for fetch-unclean-ntfs.sh. Phases:
#   setup   a fixed 256 MB VHD, NTFS, baseline files flushed to disk, then a manifest
#   burst   keeps creating, renaming and deleting files without flushing, until
#           the Mac powers the VM off (an unplug while Windows writes)
#   upload  after the reboot, sends the VHD (never attached again) to the Mac
#   check   attaches a VHD the Mac recovered and runs chkdsk read-only on it
param([Parameter(Mandatory)][ValidateSet('setup','burst','upload','check')][string]$Phase,
      [string]$Server = 'http://10.211.55.2:8766', [string]$Files = 'http://10.211.55.2:8765')
$ErrorActionPreference = 'Stop'
$dir = 'C:\Windows\Temp\unclean'
$vhd = "$dir\unclean.vhd"
$letter = 'U'

function Run-Diskpart([string[]]$lines) {
    $script = "$dir\diskpart.txt"
    Set-Content -Path $script -Value $lines -Encoding ASCII
    diskpart /s $script | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "diskpart failed: $($lines -join '; ')" }
}

switch ($Phase) {
  'setup' {
    New-Item -ItemType Directory -Force $dir | Out-Null
    if (Test-Path $vhd) { Run-Diskpart @("select vdisk file=$vhd", 'detach vdisk noerr'); Remove-Item $vhd -Force }
    Run-Diskpart @("create vdisk file=$vhd maximum=256 type=fixed", "select vdisk file=$vhd", 'attach vdisk',
                   'convert mbr', 'create partition primary', 'format fs=ntfs quick label=UNCLEAN', "assign letter=$letter")
    $root = "${letter}:\"
    $manifest = @()
    foreach ($d in 1..8) {
      $folder = Join-Path $root "base-$d"
      New-Item -ItemType Directory -Force $folder | Out-Null
      foreach ($f in 1..25) {
        $path = Join-Path $folder "file-$f.txt"
        $text = "baseline $d/$f " + ('x' * (64 * $f))
        Set-Content -Path $path -Value $text -Encoding UTF8 -NoNewline
        $manifest += "{0}`t{1}" -f ($path.Substring(3)), (Get-FileHash $path -Algorithm SHA256).Hash
      }
    }
    Set-Content -Path "$dir\baseline.tsv" -Value $manifest -Encoding UTF8
    Write-VolumeCache -DriveLetter $letter
    'READY'
  }
  'burst' {
    $root = "${letter}:\"
    $i = 0
    while ($true) {
      $i++
      $folder = Join-Path $root ("burst-{0}" -f ($i % 40))
      New-Item -ItemType Directory -Force $folder | Out-Null
      $path = Join-Path $folder "new-$i.txt"
      Set-Content -Path $path -Value ("burst $i " + ('y' * (32 * ($i % 50)))) -Encoding UTF8 -NoNewline
      if ($i % 3 -eq 0) { Rename-Item -Path $path -NewName "renamed-$i.txt" }
      if ($i % 5 -eq 0) { Remove-Item -Path (Join-Path $root ("base-{0}\file-{1}.txt" -f (($i % 8) + 1), (($i % 25) + 1))) -ErrorAction SilentlyContinue }
    }
  }
  'upload' {
    # Never attach it here: Windows would replay its own log on mount.
    Invoke-WebRequest -UseBasicParsing -Method Put -InFile $vhd -Uri "$Server/unclean.vhd" | Out-Null
    Invoke-WebRequest -UseBasicParsing -Method Put -InFile "$dir\baseline.tsv" -Uri "$Server/baseline.tsv" | Out-Null
    'UPLOADED'
  }
  'check' {
    $checked = "$dir\recovered.vhd"
    Invoke-WebRequest -UseBasicParsing -Uri "$Files/recovered.vhd" -OutFile $checked
    Run-Diskpart @("select vdisk file=$checked", 'attach vdisk readonly')
    Start-Sleep -Seconds 3
    $volume = Get-Disk | Where-Object Location -like "*recovered.vhd" | Get-Partition | Get-Volume
    $result = chkdsk "$($volume.DriveLetter):" 2>&1 | Out-String
    Run-Diskpart @("select vdisk file=$checked", 'detach vdisk')
    $result
  }
}
