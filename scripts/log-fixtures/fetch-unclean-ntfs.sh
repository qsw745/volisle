#!/bin/zsh
# Builds .workbench/log-fixtures/unclean.img (git-ignored): an NTFS volume that
# Windows 11 was writing to when it was cut off, as when a disk is unplugged
# without Safe Removal. In the Parallels "Windows 11" VM: a fixed VHD is
# formatted and filled (baseline flushed), files are created and renamed
# without flushing, the VM is powered off mid-write, and after the reboot the
# VHD comes back unattached. Used by scripts/test-windows-log-recover.py.
set -euo pipefail
cd "${0:A:h:h:h}"
out=.workbench/log-fixtures; mkdir -p $out
vm="Windows 11"
python3 scripts/bitlocker-fixtures/put_server.py $out & server=$!
python3 -m http.server 8765 --bind 10.211.55.2 --directory scripts/log-fixtures >/dev/null 2>&1 & files=$!
trap 'kill $server $files 2>/dev/null' EXIT
wait_vm() {
  for i in $(seq 1 40); do r=$(timeout 30 prlctl exec "$vm" cmd /c "echo ok" 2>/dev/null | tr -d '\r\n' || true); [[ $r == ok ]] && return 0; sleep 10; done
  echo "Windows 虚拟机命令通道不可用（可能需要登录 Windows）"; exit 1
}
# run_phase <seconds> <phase>: one phase of make-unclean-ntfs.ps1 inside the VM.
run_phase() { timeout $1 prlctl exec "$vm" powershell -NoProfile -ExecutionPolicy Bypass -File C:/Windows/Temp/unclean/make-unclean-ntfs.ps1 -Phase $2 | tr -d '\r'; }
prlctl list -a | grep -q "running.*$vm" || prlctl resume "$vm" >/dev/null 2>&1 || prlctl start "$vm" >/dev/null
wait_vm
sleep 1
# Long inline commands fail in prlctl exec: the VM downloads the script and
# rewrites it with a UTF-8 BOM for PowerShell 5.
timeout 120 prlctl exec "$vm" powershell -NoProfile -Command "New-Item -ItemType Directory -Force C:/Windows/Temp/unclean | Out-Null; Invoke-WebRequest -UseBasicParsing http://10.211.55.2:8765/make-unclean-ntfs.ps1 -OutFile C:/Windows/Temp/unclean/make-unclean-ntfs.ps1; \$p='C:/Windows/Temp/unclean/make-unclean-ntfs.ps1'; [IO.File]::WriteAllText(\$p, [IO.File]::ReadAllText(\$p, [Text.Encoding]::UTF8), [Text.UTF8Encoding]::new(\$true))"
run_phase 300 setup | grep -q READY || { echo '准备测试盘失败'; exit 1; }
# Write without flushing, then cut the power while Windows is still writing.
( run_phase 120 burst >/dev/null 2>&1 || true ) & burst=$!
sleep ${BURST_SECONDS:-20}
prlctl stop "$vm" --kill >/dev/null
wait $burst  # not plain wait: the two file servers never exit
prlctl start "$vm" >/dev/null
wait_vm
run_phase 600 upload | grep -q UPLOADED || { echo '取回测试盘失败'; exit 1; }
python3 - $out/unclean.vhd $out/unclean.img <<'PY'
import struct, sys
src, dst = sys.argv[1:]
with open(src, 'rb') as f:
    mbr = f.read(512)
    assert mbr[510:512] == b'\x55\xaa', 'no MBR'
    start, count = struct.unpack_from('<II', mbr, 446 + 8)
    f.seek(start * 512); data = f.read(count * 512)
assert data[3:11] == b'NTFS    ', 'partition is not NTFS'
open(dst, 'wb').write(data)
print(dst, len(data))
PY
