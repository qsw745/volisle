#!/bin/zsh
# Builds the test VM runner. Local use only: ad-hoc signed with the
# virtualization entitlement (no restricted entitlement is needed for NAT).
#
# Output goes to the internal disk (~/VolisleVM/bin by default), not next to
# the source: this repository lives on a USB drive, and a runner started from
# there crashes (SIGBUS) when the Mac wakes before that drive is back and a
# code page has to be read again (seen 2026-10-08). Writes both the command
# line tool and VolisleVM.app, the same binary in a bundle.
set -euo pipefail
here=${0:A:h}
out=${1:-$HOME/VolisleVM/bin}
mkdir -p "$out"
[[ $(df -P "$out" | awk 'NR==2 {print $6}') == /Volumes/* ]] \
  && print -u2 "注意：$out 不在内置硬盘上，外接盘睡眠后虚拟机启动器可能崩溃"
swiftc -swift-version 5 -O -parse-as-library "$here/VolisleVM.swift" \
  -framework Virtualization -framework AppKit -o "$out/volisle-vm"
codesign --force --sign - --entitlements "$here/vm.entitlements" "$out/volisle-vm"

app=$out/VolisleVM.app
mkdir -p "$app/Contents/MacOS"
cp "$out/volisle-vm" "$app/Contents/MacOS/VolisleVM"
plutil -create xml1 "$app/Contents/Info.plist"
for key value in CFBundleExecutable VolisleVM CFBundleIdentifier top.qisw.volisle.vmtest CFBundleName VolisleVM \
                 CFBundleDisplayName VolisleVM CFBundlePackageType APPL CFBundleVersion 1 LSMinimumSystemVersion 15.0; do
  plutil -insert $key -string $value "$app/Contents/Info.plist"
done
codesign --force --sign - --entitlements "$here/vm.entitlements" "$app"
print "$out/volisle-vm"
print "$app"
