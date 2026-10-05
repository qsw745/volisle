# Runs inside the Windows 11 Pro VM with the qsw test disk (Seagate Expansion)
# attached: replaces the BitLocker test partition in front of qsw with a fresh
# one that Windows formats and encrypts with the test password, and writes
# a few files with hashes Windows computes. Never touches the qsw partition.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$disk = Get-Disk | Where-Object FriendlyName -eq 'Seagate Expansion'
if (-not $disk) { throw 'Seagate Expansion not attached' }
$n = $disk.Number
$start = 210763776                 # 201 MiB: right after the EFI partition
$qsw = Get-Partition -DiskNumber $n | Where-Object Offset -eq 1023410176
if (-not $qsw -or $qsw.Size -lt 1TB) { throw 'qsw partition not where expected' }
Get-Partition -DiskNumber $n | Where-Object { $_.Offset -ge $start -and $_.Offset -lt $qsw.Offset } | Remove-Partition -Confirm:$false
$size = $qsw.Offset - $start
$p = New-Partition -DiskNumber $n -Offset $start -Size $size -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
$p | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'BDETEST' -Confirm:$false | Out-Null
$p | Set-Partition -NewDriveLetter T
$v = 'T:'
New-Item -ItemType Directory -Force "$v\照片\2026" | Out-Null
[IO.File]::WriteAllText("$v\说明.txt", "盘屿 BitLocker 实盘测试`n", [Text.UTF8Encoding]::new($false))
$bytes = [byte[]]::new(8MB)
for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [byte](($i * 7 + 13) % 251) }
[IO.File]::WriteAllBytes("$v\照片\2026\pattern.bin", $bytes)
$password = ConvertTo-SecureString 'Volisle-Test-2026!' -AsPlainText -Force
Enable-BitLocker -MountPoint $v -EncryptionMethod XtsAes128 -PasswordProtector -Password $password | Out-Null
Add-BitLockerKeyProtector -MountPoint $v -RecoveryPasswordProtector | Out-Null
while ((Get-BitLockerVolume -MountPoint $v).VolumeStatus -ne 'FullyEncrypted') { Start-Sleep 3 }
$b = Get-BitLockerVolume -MountPoint $v
$files = Get-ChildItem -Recurse -File $v\ | Where-Object FullName -notlike '*System Volume Information*' | ForEach-Object {
  @{ path = $_.FullName.Substring(3).Replace('\', '/'); size = $_.Length; sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower() }
}
@{ offset = $start; size = $size; method = [string]$b.EncryptionMethod; password = 'Volisle-Test-2026!';
   recovery = ($b.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword').RecoveryPassword; files = $files } | ConvertTo-Json -Depth 5
