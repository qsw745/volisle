#!/usr/bin/env python3
"""Test production build rejection without compiling, signing or uploading."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BuildGuardTests(unittest.TestCase):
    def run_script(self, name, args, config='', flag=False):
        with tempfile.TemporaryDirectory(prefix='volisle-build-guard-') as directory:
            root = Path(directory)
            script = root / name
            script.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, script)
            (root / 'config').mkdir(exist_ok=True)
            (root / 'config/release.local.env').write_text(config)
            library = root / '.workbench/ntfs-3g-2026.9.28/libntfs-3g/.libs/libntfs-3g.a'
            library.parent.mkdir(parents=True)
            library.write_bytes(b'not a real library; compilation must never start')
            tools = root / 'tools'
            tools.mkdir()
            clang = tools / 'clang'
            clang.write_text('#!/bin/sh\necho COMPILE_REACHED >&2\nexit 77\n')
            clang.chmod(0o755)
            env = {k: v for k, v in os.environ.items() if not k.startswith('VOLISLE_')}
            env['PATH'] = str(tools) + os.pathsep + env['PATH']
            if flag:
                env['VOLISLE_TEST_CHECKPOINT_FAIL'] = '1'
            return subprocess.run(['zsh', str(script), *args], env=env, capture_output=True, text=True)

    def test_website_build_rejects_fault_flag_before_compiling(self):
        result = self.run_script('scripts/build-fskit-extension.sh', ['--daily-write'], flag=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('官网构建拒绝启用', result.stderr)
        self.assertNotIn('COMPILE_REACHED', result.stderr)

    def test_store_package_rejects_fault_flag_in_environment(self):
        result = self.run_script('scripts/store/build-store-package.sh', ['10'], flag=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('VOLISLE_TEST_CHECKPOINT_FAIL 只用于本地测试包', result.stderr)

    def test_store_package_rejects_fault_flag_from_local_config(self):
        result = self.run_script('scripts/store/build-store-package.sh', ['10'],
                                 config='VOLISLE_TEST_CHECKPOINT_FAIL=1\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('正式商店包拒绝配置文件中的测试开关', result.stderr)


if __name__ == '__main__':
    unittest.main()
