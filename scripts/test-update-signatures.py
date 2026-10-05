#!/usr/bin/env python3
"""Exercise the locally built Sparkle verifier with disposable test keys only."""
import base64
import os
from pathlib import Path
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[1]
TOOL=ROOT/'.workbench/sparkle-build/Build/Products/Release/sign_update'

def invoke(key,*args):
    return subprocess.run([str(TOOL),'--ed-key-file',str(key),*map(str,args)],capture_output=True,text=True)

with tempfile.TemporaryDirectory(prefix='volisle-update-signatures-') as folder:
    root=Path(folder);key=root/'test-key';key.write_bytes(base64.b64encode(os.urandom(32)));key.chmod(0o600)
    wrong=root/'wrong-key';wrong.write_bytes(base64.b64encode(os.urandom(32)));wrong.chmod(0o600)
    update=root/'fixture.zip';update.write_bytes(b'disposable signature fixture, not an installable update')
    signed=invoke(key,'-p',update);assert signed.returncode==0,signed.stderr
    signature=signed.stdout.strip()
    assert invoke(key,'--verify',update,signature).returncode==0
    assert invoke(wrong,'--verify',update,signature).returncode!=0
    update.write_bytes(update.read_bytes()+b'tampered')
    assert invoke(key,'--verify',update,signature).returncode!=0
    feed=root/'appcast.xml';feed.write_text('<?xml version="1.0"?><rss version="2.0"><channel><title>Disposable test</title></channel></rss>')
    assert invoke(key,'--verify',feed).returncode!=0
    result=invoke(key,feed);assert result.returncode==0,result.stderr
    assert invoke(key,'--verify',feed).returncode==0
    assert invoke(wrong,'--verify',feed).returncode!=0
    feed.write_bytes(feed.read_bytes().replace(b'Disposable test',b'Tampered test'))
    assert invoke(key,'--verify',feed).returncode!=0
print('Sparkle 实际验签通过：正确包及目录接受；未签名、错误密钥、篡改包及目录全部拒绝。仅一次性测试密钥，无生产私钥访问。')
