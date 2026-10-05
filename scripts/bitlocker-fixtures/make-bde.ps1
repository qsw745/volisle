# Runs inside the Windows 11 Pro VM (Parallels "Windows 11"): creates four fully
# encrypted 160 MB NTFS volumes in fixed VHDs (XTS/CBC, 128/256) with a password
# and a recovery password, records file hashes Windows computed, and uploads
# each VHD and its JSON to the host's PUT server (fetch.sh). Also one plain
# (unencrypted) 64 MB NTFS volume as Windows 11 formats it. Test data only.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = 'C:\Windows\Temp\bde'
New-Item -ItemType Directory -Force $root | Out-Null
$password = 'Volisle-Test-2026!'
$secure = ConvertTo-SecureString $password -AsPlainText -Force
$sets = @(
  @{ name = 'xts128'; method = 'XtsAes128'; letter = 'P' },
  @{ name = 'xts256'; method = 'XtsAes256'; letter = 'Q' },
  @{ name = 'cbc128'; method = 'Aes128';    letter = 'R' },
  @{ name = 'cbc256'; method = 'Aes256';    letter = 'S' }
)
foreach ($s in $sets) {
  $vhd = "$root\$($s.name).vhd"
  if (Test-Path $vhd) { Remove-Item $vhd }
  $script = "create vdisk file=$vhd maximum=160 type=fixed`nattach vdisk`ncreate partition primary`nformat fs=ntfs quick label=BDE$($s.name.ToUpper())`nassign letter=$($s.letter)`n"
  Set-Content -Encoding ascii "$root\dp.txt" $script
  diskpart /s "$root\dp.txt" | Out-Null
  $v = "$($s.letter):"
  New-Item -ItemType Directory -Force "$v\照片\2026" | Out-Null
  [IO.File]::WriteAllText("$v\说明.txt", "盘屿 BitLocker 测试 $($s.name)`n", [Text.Encoding]::UTF8)
  $bytes = [byte[]]::new(3MB)
  for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [byte](($i * 7 + 13) % 251) }
  [IO.File]::WriteAllBytes("$v\照片\2026\pattern.bin", $bytes)
  Enable-BitLocker -MountPoint $v -EncryptionMethod $s.method -PasswordProtector -Password $secure | Out-Null
  Add-BitLockerKeyProtector -MountPoint $v -RecoveryPasswordProtector | Out-Null
  while ((Get-BitLockerVolume -MountPoint $v).VolumeStatus -ne 'FullyEncrypted') { Start-Sleep 2 }
  $b = Get-BitLockerVolume -MountPoint $v
  $recovery = ($b.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword').RecoveryPassword
  $files = Get-ChildItem -Recurse -File $v\ | Where-Object FullName -notlike '*System Volume Information*' | ForEach-Object {
    @{ path = $_.FullName.Substring(3).Replace('\', '/'); size = $_.Length; sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower() }
  }
  $meta = @{ name = $s.name; method = [string]$b.EncryptionMethod; password = $password; recovery = $recovery; files = $files }
  [IO.File]::WriteAllText("$root\$($s.name).json", ($meta | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
  Set-Content -Encoding ascii "$root\dp.txt" "select vdisk file=$vhd`ndetach vdisk`n"
  diskpart /s "$root\dp.txt" | Out-Null
  foreach ($f in @("$($s.name).vhd", "$($s.name).json")) {
    Invoke-WebRequest -UseBasicParsing -Method Put -InFile "$root\$f" -Uri "http://10.211.55.2:8766/$f" | Out-Null
  }
  "$($s.name) $($b.EncryptionMethod) uploaded"
}

# A plain volume exactly as Windows 11 formats it (its $Volume flags carry 0x0080).
$vhd = "$root\win11-plain.vhd"
if (Test-Path $vhd) { Remove-Item $vhd }
Set-Content -Encoding ascii "$root\dp.txt" "create vdisk file=$vhd maximum=64 type=fixed`nattach vdisk`ncreate partition primary`nformat fs=ntfs quick label=PLAIN`nassign letter=W`n"
diskpart /s "$root\dp.txt" | Out-Null
[IO.File]::WriteAllText("W:\a.txt", "hello`n", [Text.UTF8Encoding]::new($false))
Set-Content -Encoding ascii "$root\dp.txt" "select vdisk file=$vhd`ndetach vdisk`n"
diskpart /s "$root\dp.txt" | Out-Null
Invoke-WebRequest -UseBasicParsing -Method Put -InFile $vhd -Uri "http://10.211.55.2:8766/win11-plain.vhd" | Out-Null
"win11-plain uploaded"
