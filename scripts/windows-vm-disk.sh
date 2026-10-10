#!/bin/zsh
# Moves the qsw test disk (Seagate Expansion, USB) between this Mac and the
# Parallels "Windows 11" VM. Never touches any other disk.
#   windows-vm-disk.sh attach   end Volisle's write session, unmount, hand to the VM
#   windows-vm-disk.sh detach   cleanly dismount every NTFS volume in Windows, hand back
# Detach matters: a volume Windows still has mounted (even one without a drive
# letter) comes back with an unclean $LogFile, and Volisle rightly keeps it read-only.
# BitLocker volumes unlocked in Windows are locked again first.
set -euo pipefail
vm="Windows 11"
usb=$(prlsrvctl usb list | grep -A2 "Device: 'Expansion'" | sed -nE "s/.*System name: '([^']+)'.*/\1/p")
[[ -n $usb ]] || { echo "Expansion 不在 USB 列表中"; exit 1; }
vm_ready() {
  for t in 1 2 3 4; do
    prlctl resume "$vm" >/dev/null 2>&1 || true; sleep 25
    for i in 1 2 3 4 5 6; do r=$(timeout 30 prlctl exec "$vm" cmd /c "echo ok" 2>/dev/null | tr -d '\r\n' || true); [[ $r == ok ]] && break; sleep 5; done
    n=$(timeout 60 prlctl exec "$vm" powershell -NoProfile -Command "(Get-Disk | Where-Object FriendlyName -eq 'Seagate Expansion').Number" 2>/dev/null | tr -d '\r\n ' || true)
    [[ -n $n ]] && { echo "Windows 磁盘号 $n"; return 0; }
    prlctl suspend "$vm" >/dev/null 2>&1 || true; sleep 5
  done
  return 1
}
case ${1:-} in
attach)
  disk=$(diskutil list external physical | awk '/^\/dev\/disk/ {print $1}' | while read d; do diskutil info $d | grep -q "Media Name:.*Expansion" && echo ${d#/dev/}; done | head -1)
  [[ -n $disk ]] || { echo "Mac 上找不到 Expansion"; exit 1; }
  # Where build-local-candidate.sh installs: /Applications since 0.8.1, VOLISLE_TEST_APP overrides.
  app=${VOLISLE_TEST_APP:-}
  [[ -n $app ]] || { [[ -d /Applications/Volisle.app ]] && app=/Applications/Volisle.app || app=~/Applications/"Volisle Test.app"; }
  B=$app/Contents/MacOS/Volisle
  osascript -e 'tell application id "top.qisw.volisle" to quit' 2>/dev/null || true; sleep 3
  if mount | grep -q "^/dev/${disk}s[0-9]* on .*(volisle"; then
    id=$($B --helper-cycle-latest | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")
    $B --helper-cycle-recover $id >/dev/null
    for i in $(seq 1 90); do p=$($B --helper-cycle-latest | python3 -c "import json,sys;print(json.load(sys.stdin)['phase'])"); [[ $p == finished ]] && break; sleep 1; done
  fi
  diskutil unmountDisk $disk
  prlsrvctl usb set "$usb" "$vm" >/dev/null
  vm_ready
  timeout 120 prlctl exec "$vm" powershell -NoProfile -Command "Set-Disk -Number (Get-Disk | Where-Object FriendlyName -eq 'Seagate Expansion').Number -IsOffline \$false" ;;
detach)
  timeout 300 prlctl exec "$vm" powershell -NoProfile -Command "\$n=(Get-Disk | Where-Object FriendlyName -eq 'Seagate Expansion').Number; if (\$n -eq \$null) { exit 1 }; \$used=@((Get-Volume).DriveLetter); \$free=[char[]](71..90) | Where-Object { \$used -notcontains \$_ }; \$i=0; foreach (\$p in Get-Partition -DiskNumber \$n | Where-Object DriveLetter -match '[A-Z]') { \$b=Get-BitLockerVolume -MountPoint ([string]\$p.DriveLetter + ':') -ErrorAction SilentlyContinue; if (\$b.LockStatus -eq 'Unlocked' -and \$b.VolumeType -ne 'OperatingSystem') { Lock-BitLocker -MountPoint \$b.MountPoint | Out-Null; 'locked BitLocker ' + \$b.MountPoint } }; foreach (\$p in Get-Partition -DiskNumber \$n) { \$v=\$p | Get-Volume -ErrorAction SilentlyContinue; if (\$v.FileSystem -ne 'NTFS') { continue }; if (-not ([string]\$p.DriveLetter -match '[A-Z]')) { \$p | Set-Partition -NewDriveLetter \$free[\$i]; \$i++; Start-Sleep 2; \$p=Get-Partition -DiskNumber \$n -PartitionNumber \$p.PartitionNumber }; \$l=[string]\$p.DriveLetter + ':'; mountvol \$l /p; 'dismounted ' + \$v.FileSystemLabel }" | tr -d '\r'
  sleep 3
  prlsrvctl usb del "$usb" >/dev/null
  prlctl suspend "$vm" >/dev/null
  for i in $(seq 1 30); do sleep 3; diskutil list external physical | grep -q "Expansion\|qsw" && break; done
  diskutil list external physical | grep -A8 "2.0 TB" ;;
*) echo "用法：$0 attach|detach"; exit 2 ;;
esac
