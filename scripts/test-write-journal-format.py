#!/usr/bin/env python3
"""Compile the real journal store and test only disposable local records.

No NTFS bridge, volume, extension container, mount or recovery is used.
Build output, test output and every fixture remain in a new /private/tmp folder.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    output = Path(tempfile.mkdtemp(prefix="volisle-journal-format-", dir="/private/tmp"))
    binary = output / "regression"
    env = {**os.environ, "CLANG_MODULE_CACHE_PATH": str(output / "module-cache")}
    command = [
        "swiftc", "-swift-version", "6", "-module-cache-path", str(output / "module-cache"),
        str(ROOT / "apps/extension/Sources/WriteJournalStore.swift"),
        str(ROOT / "scripts/fixtures/write_journal_format_regression.swift"), "-o", str(binary),
    ]
    built = subprocess.run(command, capture_output=True, text=True, env=env)
    (output / "build.log").write_text(built.stdout + built.stderr)
    if built.returncode:
        print(built.stdout + built.stderr, file=sys.stderr)
        print(f"编译证据：{output}", file=sys.stderr)
        return built.returncode
    tested = subprocess.run([str(binary), str(output)], capture_output=True, text=True, env=env)
    (output / "test.log").write_text(tested.stdout + tested.stderr)
    print(tested.stdout, end="")
    if tested.stderr:
        print(tested.stderr, file=sys.stderr, end="")
    print(f"证据目录：{output}")
    return tested.returncode


if __name__ == "__main__":
    sys.exit(main())
