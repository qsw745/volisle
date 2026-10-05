#!/usr/bin/env python3
"""Exercise real Sparkle failure paths using isolated apps and loopback HTTP.

Requires the locally built UpdateFailureFixture and Sparkle. Uses a disposable
Ed25519 key and ad-hoc test apps; never reads production update credentials,
modifies installed Volisle, registers its helper, or opens a disk device.
"""
import argparse
import base64
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SPARKLE = ROOT / '.workbench/sparkle-build/Build/Products/Release'
FIXTURE = ROOT / 'scripts/fixtures/update-failure/.build/out/Build/Products/Release/UpdateFailureFixture'
NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
EXPECTED_ERRORS = {'unavailable': 2001, 'unsigned-feed': 1000, 'tampered-feed': 1000,
                   'truncated': 2001, 'bad-archive-signature': 4005, 'invalid-archive': 3000}


def run(*args):
    return subprocess.check_output(list(map(str, args)), stderr=subprocess.STDOUT, text=True).strip()


def snapshot(app):
    result = {}
    for path in sorted(app.rglob('*')):
        name = str(path.relative_to(app))
        if path.is_symlink(): result[name] = 'link:' + os.readlink(path)
        elif path.is_file(): result[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', required=True, type=Path)
    args = parser.parse_args()
    if args.output_dir.exists(): parser.error('输出目录已存在，请保留旧证据并指定新目录')
    if not FIXTURE.is_file(): parser.error('请先在 scripts/fixtures/update-failure 本机构建测试应用')
    out = args.output_dir.resolve(); out.mkdir(parents=True)
    requests = []

    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, fmt, *values): requests.append(fmt % values)
        def do_GET(self):
            if self.path.startswith('/unavailable/'):
                self.send_error(503); return
            if self.path == '/truncated/update.zip':
                data = (out / 'truncated/update.zip').read_bytes()
                self.send_response(200)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data[:len(data)//3]); self.wfile.flush()
                self.connection.shutdown(socket.SHUT_RDWR); self.connection.close()
                return
            super().do_GET()

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(out)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    results = []
    domains = []
    try:
        with tempfile.TemporaryDirectory(prefix='volisle-update-test-key-') as temporary:
            key = Path(temporary) / 'test-key'
            key.write_bytes(base64.b64encode(os.urandom(32))); key.chmod(0o600)
            # Public-key derivation uses CryptoKit; production Keychain is never opened.
            swift = Path(temporary) / 'public.swift'
            swift.write_text('import Foundation\nimport CryptoKit\nlet d = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))\nlet k = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: d)!)\nprint(k.publicKey.rawRepresentation.base64EncodedString())\n')
            public = run('swift', swift, key)
            for case in ['unavailable', 'unsigned-feed', 'tampered-feed', 'truncated', 'bad-archive-signature', 'invalid-archive']:
                folder = out / case; folder.mkdir()
                app = folder / 'UpdateFailureFixture.app'
                contents = app / 'Contents'; (contents / 'MacOS').mkdir(parents=True)
                (contents / 'Frameworks').mkdir()
                shutil.copy2(FIXTURE, contents / 'MacOS/UpdateFailureFixture')
                shutil.copytree(SPARKLE / 'Sparkle.framework', contents / 'Frameworks/Sparkle.framework', symlinks=True)
                domain = 'top.qisw.volisle.failure-' + uuid.uuid4().hex
                domains.append(domain)
                info = dict(CFBundleIdentifier=domain, CFBundleName='Volisle Update Failure Fixture',
                    CFBundleExecutable='UpdateFailureFixture', CFBundlePackageType='APPL', CFBundleVersion='1',
                    CFBundleShortVersionString='1.0', LSMinimumSystemVersion='26.4', LSUIElement=True,
                    SUFeedURL=f'{base}/{case}/appcast.xml', SUPublicEDKey=public, SURequireSignedFeed=True,
                    SUVerifyUpdateBeforeExtraction=True, SUEnableAutomaticChecks=False, SUSendProfileInfo=False,
                    FixtureLog=str(folder / 'events.log'), NSAppTransportSecurity={'NSAllowsLocalNetworking': True})
                (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
                run('codesign', '--force', '--sign', '-', app)
                archive = folder / 'update.zip'
                # Valid ZIP/container and higher bundle version, never installed by these tests.
                target = folder / 'target/UpdateFailureFixture.app'
                shutil.copytree(app, target, symlinks=True)
                target_info = dict(info, CFBundleVersion='2', CFBundleShortVersionString='2.0')
                (target / 'Contents/Info.plist').write_bytes(plistlib.dumps(target_info))
                run('codesign', '--force', '--sign', '-', target)
                run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', target, archive)
                if case == 'invalid-archive': archive.write_bytes(b'Not a ZIP, but correctly signed for extraction failure coverage.')
                signature = run(SPARKLE / 'sign_update', '--ed-key-file', key, '-p', archive)
                if case == 'bad-archive-signature':
                    raw = bytearray(base64.b64decode(signature)); raw[0] ^= 1
                    signature = base64.b64encode(raw).decode()
                ET.register_namespace('sparkle', NS)
                rss = ET.Element('rss', version='2.0'); channel = ET.SubElement(rss, 'channel')
                ET.SubElement(channel, 'title').text = 'Local failure fixture'
                item = ET.SubElement(channel, 'item')
                ET.SubElement(item, '{'+NS+'}version').text = '2'
                ET.SubElement(item, '{'+NS+'}shortVersionString').text = '2.0'
                ET.SubElement(item, 'enclosure', {'url': f'{base}/{case}/update.zip', 'length': str(archive.stat().st_size),
                    'type': 'application/octet-stream', '{'+NS+'}edSignature': signature})
                feed = folder / 'appcast.xml'
                ET.ElementTree(rss).write(feed, encoding='utf-8', xml_declaration=True)
                if case != 'unsigned-feed': run(SPARKLE / 'sign_update', '--ed-key-file', key, feed)
                if case == 'tampered-feed': feed.write_bytes(feed.read_bytes().replace(b'Local failure fixture', b'Changed failure fixture'))
            # All inputs prepared; destroy disposable keys before running apps.
        for folder in sorted(p for p in out.iterdir() if p.is_dir()):
            case = folder.name; app = folder / 'UpdateFailureFixture.app'
            before = snapshot(app)
            log = folder / 'events.log'
            with (folder / 'process.log').open('w') as stream:
                process = subprocess.Popen([str(app / 'Contents/MacOS/UpdateFailureFixture')], stdout=stream, stderr=stream)
                try: process.wait(timeout=45)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    try: process.wait(timeout=5)
                    except subprocess.TimeoutExpired: process.kill(); process.wait()
            events = log.read_text().splitlines() if log.exists() else []
            rejected = f'rejected:SUSparkleErrorDomain:{EXPECTED_ERRORS[case]}' in events
            required = ['launched:1', 'checking']
            if case in ['truncated', 'bad-archive-signature', 'invalid-archive']: required += ['found:2', 'downloading']
            if case == 'invalid-archive': required += ['extracting']
            unchanged = before == snapshot(app)
            passed = process.returncode == 0 and rejected and unchanged and all(x in events for x in required) and not any(x.startswith('UNEXPECTED:') for x in events)
            results.append(dict(case=case, passed=passed, originalBundleUnchanged=unchanged, events=events, exitCode=process.returncode))
            print(json.dumps(results[-1], ensure_ascii=False), flush=True)
    finally:
        server.shutdown(); server.server_close()
        # Only the per-run disposable fixture preference domains are touched.
        for domain in domains: subprocess.run(['defaults', 'delete', domain], capture_output=True)
        (out / 'result.json').write_text(json.dumps(dict(cases=results, requests=requests, localServerStopped=True), ensure_ascii=False, indent=2)+'\n')
    if len(results) != 6 or not all(x['passed'] for x in results): raise SystemExit(1)


if __name__ == '__main__': main()
