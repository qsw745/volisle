# Runs inside the Parallels "Windows 11" VM (fetch-rich-ntfs.sh): formats a
# 380 MB NTFS volume in a fixed VHD the way Windows does, fills it with the
# structures real Windows disks carry, marks it "needs check" (dirty) and
# uploads the VHD to the host's PUT server. "Check on This Mac" must accept all
# of it: none of it is damage. Test data only. Each step reports ok or FAIL.
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = 'C:\Windows\Temp\rich'
New-Item -ItemType Directory -Force $root | Out-Null
$vhd = "$root\rich.vhd"
if (Test-Path $vhd) {
  Set-Content -Encoding ascii "$root\dp.txt" "select vdisk file=$vhd`ndetach vdisk`n"
  diskpart /s "$root\dp.txt" | Out-Null
  Remove-Item $vhd
}
Set-Content -Encoding ascii "$root\dp.txt" "create vdisk file=$vhd maximum=380 type=fixed`nattach vdisk`ncreate partition primary`nformat fs=ntfs quick label=RICH`nassign letter=V`n"
diskpart /s "$root\dp.txt" | Out-Null
$v = 'V:'
function Step($name, [scriptblock]$body) {
  try { & $body | Out-Null; "ok   $name" } catch { "FAIL $name : $($_.Exception.Message)" }
}

Step '8.3 short names' { fsutil 8dot3name set V: 0 }
Step 'many small files' {
  foreach ($d in 1..30) {
    $p = "$v\many\folder $d"; New-Item -ItemType Directory -Force $p | Out-Null
    foreach ($i in 1..100) { [IO.File]::WriteAllText("$p\a file with a long name $i.txt", "content $d $i") }
  }
}
Step 'directory with 6000 entries' {
  New-Item -ItemType Directory -Force "$v\bigdir" | Out-Null
  foreach ($i in 1..6000) { [IO.File]::WriteAllText("$v\bigdir\entry_$i.dat", "$i") }
}
Step 'deep path over 260 characters' {
  $p = "$v\deep"; foreach ($i in 1..40) { $p = "$p\level$i" }
  [IO.Directory]::CreateDirectory("\\?\$p") | Out-Null
  [IO.File]::WriteAllText("\\?\$p\leaf.txt", 'deep')
}
Step 'Chinese, emoji and decomposed names' {
  New-Item -ItemType Directory -Force "$v\中文目录\照片 2026" | Out-Null
  [IO.File]::WriteAllText("$v\中文目录\照片 2026\测试 文件😀.txt", '你好')
  [IO.File]::WriteAllText("$v\中文目录\cafe" + [char]0x0301 + ".txt", 'nfd')
}
Step 'hard links' {
  [IO.File]::WriteAllText("$v\linked.txt", 'linked')
  New-Item -ItemType Directory -Force "$v\links" | Out-Null
  foreach ($i in 1..20) { cmd /c mklink /H "$v\links\link$i.txt" "$v\linked.txt" }
}
Step 'directory junction' {
  New-Item -ItemType Directory -Force "$v\target\inside" | Out-Null
  cmd /c mklink /J "$v\junction" "$v\target"
}
Step 'symbolic links' {
  cmd /c mklink "$v\filelink.txt" "$v\linked.txt"
  cmd /c mklink /D "$v\dirlink" "$v\target"
  cmd /c mklink "$v\relative-link.txt" "linked.txt"
}
Step 'compressed folder' {
  New-Item -ItemType Directory -Force "$v\compressed" | Out-Null
  foreach ($i in 1..20) { [IO.File]::WriteAllText("$v\compressed\c$i.txt", ('compressible text ' * 20000)) }
  compact /c /s:"$v\compressed"
}
Step 'sparse file' {
  $f = "$v\sparse.bin"
  $fs = [IO.File]::Create($f); $fs.Close()
  fsutil sparse setflag $f
  $fs = [IO.File]::OpenWrite($f); $fs.SetLength(64MB); $fs.Seek(32MB, 'Begin') | Out-Null
  $fs.Write([byte[]](1..255), 0, 255); $fs.Close()
  fsutil sparse setrange $f 0 1048576
}
Step 'WOF compressed (compact /exe)' {
  [IO.File]::WriteAllText("$v\wof.exe", ('MZ' + ('x' * 300000)))
  compact /c /exe:lzx "$v\wof.exe"
}
Step 'alternate data streams' {
  [IO.File]::WriteAllText("$v\ads.txt", 'main')
  Set-Content -Path "$v\ads.txt" -Stream 'Zone.Identifier' -Value "[ZoneTransfer]`r`nZoneId=3"
  foreach ($i in 1..60) { Set-Content -Path "$v\ads.txt" -Stream "s$i" -Value ('stream data ' * 10) }
}
Step 'object id' { fsutil objectid create "$v\linked.txt" }
Step 'USN journal' { fsutil usn createjournal m=1048576 a=262144 V: }
Step 'case-sensitive directory' {
  New-Item -ItemType Directory -Force "$v\casedir" | Out-Null
  fsutil file setCaseSensitiveInfo "$v\casedir" enable
  [IO.File]::WriteAllText("$v\casedir\a.txt", 'lower')
  [IO.File]::WriteAllText("$v\casedir\A.txt", 'upper')
}
Step 'explicit ACLs' {
  New-Item -ItemType Directory -Force "$v\acl" | Out-Null
  foreach ($i in 1..30) {
    $f = "$v\acl\f$i.txt"; [IO.File]::WriteAllText($f, "$i")
    icacls $f /inheritance:d /grant "Users:(R)" /deny "Guest:(W)"
  }
}
Step 'desktop.ini and attributes' {
  New-Item -ItemType Directory -Force "$v\custom" | Out-Null
  [IO.File]::WriteAllText("$v\custom\desktop.ini", "[.ShellClassInfo]`r`nIconResource=C:\Windows\system32\imageres.dll,-3")
  attrib +s +h "$v\custom\desktop.ini"; attrib +r "$v\custom"
  [IO.File]::WriteAllText("$v\ro.txt", 'ro'); attrib +r +h "$v\ro.txt"
  New-Item -ItemType File -Force "$v\empty.txt" | Out-Null
}
Step 'recycle bin' {
  Add-Type -AssemblyName Microsoft.VisualBasic
  foreach ($i in 1..5) {
    $f = "$v\todelete$i.txt"; [IO.File]::WriteAllText($f, 'bye')
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($f, 'OnlyErrorDialogs', 'SendToRecycleBin')
  }
}
Step 'fragmented files' {
  $a = [IO.File]::OpenWrite("$v\frag_a.bin"); $b = [IO.File]::OpenWrite("$v\frag_b.bin")
  $buf = [byte[]]::new(64KB)
  foreach ($i in 1..400) { $a.Write($buf, 0, $buf.Length); $a.Flush($true); $b.Write($buf, 0, $buf.Length); $b.Flush($true) }
  $a.Close(); $b.Close()
}
Step 'EFS encrypted file' { [IO.File]::WriteAllText("$v\secret.txt", 'efs'); cipher /e "$v\secret.txt" }
Step 'trailing dot and space names' {
  [IO.File]::WriteAllText('\\?\V:\trailing.', 'dot'); [IO.File]::WriteAllText('\\?\V:\trailing ', 'space')
}
Step 'shadow copy' { $r = (Get-WmiObject -List Win32_ShadowCopy).Create('V:\', 'ClientAccessible'); if ($r.ReturnValue -ne 0) { throw "rc $($r.ReturnValue)" } }
Step 'mark needs check' { fsutil dirty set V: }
Set-Content -Encoding ascii "$root\dp.txt" "select vdisk file=$vhd`ndetach vdisk`n"
diskpart /s "$root\dp.txt" | Out-Null
Invoke-WebRequest -UseBasicParsing -Method Put -InFile $vhd -Uri "http://10.211.55.2:8766/rich.vhd" | Out-Null
"rich uploaded"
