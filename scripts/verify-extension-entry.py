#!/usr/bin/env python3
"""Inspect the arm64 Mach-O without running it or accessing disk resources."""
from pathlib import Path
import struct
import subprocess
import sys

binary = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / '.workbench/fskit-build/VolisleFS'
data = binary.read_bytes()
assert struct.unpack_from('<I', data)[0] == 0xfeedfacf, 'expected thin Mach-O 64'
commands = struct.unpack_from('<I', data, 16)[0]
offset = 32
text_address = entry_offset = None
for _ in range(commands):
    command, length = struct.unpack_from('<II', data, offset)
    assert length >= 8 and offset + length <= len(data)
    if command == 0x19 and data[offset+8:offset+24].rstrip(b'\0') == b'__TEXT':
        text_address = struct.unpack_from('<Q', data, offset+24)[0]
    if command == 0x80000028:
        entry_offset = struct.unpack_from('<Q', data, offset+8)[0]
    offset += length
assert text_address is not None and entry_offset is not None
symbols = subprocess.run(['nm', '-n', str(binary)], capture_output=True, text=True, check=True).stdout.splitlines()
main = [int(line.split()[0], 16) for line in symbols if line.split()[-1:] == ['_main']]
assert len(main) == 1
assert text_address + entry_offset != main[0], '扩展错误地直接以 Swift main 启动，绕过系统扩展初始化'
assert any(line.split()[-2:] == ['U', '_NSExtensionMain'] for line in symbols), '缺少系统扩展启动入口'
print('扩展 Mach-O 启动入口核验通过：使用系统扩展入口，未执行扩展。')
