#!/bin/zsh
# Regenerates .workbench/bitlocker-fixtures (git-ignored) with the Parallels
# "Windows 11" VM: runs make-bde.ps1 there, receives the VHDs, and cuts out the
# volume image (<name>.img) using the MBR partition entry; win11-plain is an
# unencrypted volume as Windows 11 formats it. Usage: fetch.sh
set -euo pipefail
cd "${0:A:h:h:h}"
out=.workbench/bitlocker-fixtures; mkdir -p $out
vm="Windows 11"
python3 scripts/bitlocker-fixtures/put_server.py $out & server=$!
trap 'kill $server 2>/dev/null' EXIT
prlctl list -a | grep -q "running.*$vm" || prlctl resume "$vm" >/dev/null 2>&1 || prlctl start "$vm" >/dev/null
for i in $(seq 1 30); do r=$(timeout 30 prlctl exec "$vm" cmd /c "echo ok" 2>/dev/null | tr -d '\r\n' || true); [[ $r == ok ]] && break; sleep 10; done
[[ $r == ok ]] || { echo "Windows 虚拟机命令通道不可用（可能需要登录 Windows）"; exit 1; }
# Long inline commands fail in prlctl exec: the VM downloads the script from a
# one-file server instead, and rewrites it with a UTF-8 BOM for PowerShell 5.
python3 -m http.server 8765 --bind 10.211.55.2 --directory scripts/bitlocker-fixtures >/dev/null 2>&1 & files=$!
trap 'kill $server $files 2>/dev/null' EXIT
sleep 1
timeout 120 prlctl exec "$vm" powershell -NoProfile -Command "New-Item -ItemType Directory -Force C:/Windows/Temp/bde | Out-Null; Invoke-WebRequest -UseBasicParsing http://10.211.55.2:8765/make-bde.ps1 -OutFile C:/Windows/Temp/bde/make-bde.ps1; \$p='C:/Windows/Temp/bde/make-bde.ps1'; [IO.File]::WriteAllText(\$p, [IO.File]::ReadAllText(\$p, [Text.Encoding]::UTF8), [Text.UTF8Encoding]::new(\$true))"
timeout 1800 prlctl exec "$vm" powershell -NoProfile -ExecutionPolicy Bypass -File C:/Windows/Temp/bde/make-bde.ps1 | tr -d '\r'
for n in xts128 xts256 cbc128 cbc256 win11-plain; do
  python3 - $out/$n.vhd $out/$n.img <<'PY'
import struct, sys
src, dst = sys.argv[1:]
with open(src, 'rb') as f:
    mbr = f.read(512)
    assert mbr[510:512] == b'\x55\xaa', 'no MBR'
    start, count = struct.unpack_from('<II', mbr, 446 + 8)
    f.seek(start * 512); data = f.read(count * 512)
assert data[3:11] in (b'-FVE-FS-', b'NTFS    '), 'partition is neither BitLocker nor NTFS'
open(dst, 'wb').write(data)
print(dst, len(data))
PY
done
