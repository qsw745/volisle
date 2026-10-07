#!/bin/zsh
# Builds the test VM runner. Local use only: ad-hoc signed with the
# virtualization entitlement (no restricted entitlement is needed for NAT).
set -euo pipefail
here=${0:A:h}
out=${1:-$here/.build}
mkdir -p "$out"
swiftc -swift-version 5 -O -parse-as-library "$here/VolisleVM.swift" \
  -framework Virtualization -framework AppKit -o "$out/volisle-vm"
codesign --force --sign - --entitlements "$here/vm.entitlements" "$out/volisle-vm"
print "$out/volisle-vm"
