#!/usr/bin/env python3
"""Prepare a signed website update locally. Does not upload or publish."""
import argparse
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / '.workbench/sparkle-build/Build/Products/Release'
ACCOUNT = 'top.qisw.volisle.updates'
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
XML_LANG = '{http://www.w3.org/XML/1998/namespace}lang'

def run(*args): return subprocess.run([str(x) for x in args], check=True, capture_output=True, text=True).stdout.strip()
def sha(path):
    with path.open('rb') as stream: return hashlib.file_digest(stream, 'sha256').hexdigest()

def verify_readiness(document, build, provenance_sha):
    if not isinstance(document, dict) or type(document.get('schema')) is not int or document['schema'] != 1:
        raise ValueError('缺少正式发行验收记录')
    blockers = document.get('blockers')
    if document.get('status') != 'ready' or not isinstance(blockers, list) or blockers:
        raise ValueError('正式发行仍被验收项阻止：' + str(blockers))
    if type(document.get('build')) is not int or document['build'] != build:
        raise ValueError('发行验收记录不属于本次构建')
    if document.get('source_provenance_sha256') != provenance_sha:
        raise ValueError('发行验收记录不属于本次源码与二进制')

def verify_source(app, source):
    receipt = json.loads((app/'Contents/Resources/SourceProvenance.json').read_text())
    if receipt.get('schema') != 1: raise ValueError('缺少对应源码记录')
    expected = receipt['files']
    with tarfile.open(source) as archive:
        members = archive.getmembers()
        if len(members) != len(expected): raise ValueError('对应源码条目数量不匹配')
        seen = set()
        for member in members:
            name = member.name.removeprefix('Volisle/')
            if not member.name.startswith('Volisle/') or name in seen or not member.isfile() or name not in expected:
                raise ValueError('对应源码条目无效')
            seen.add(name)
            if hashlib.sha256(archive.extractfile(member).read()).hexdigest() != expected[name]['sha256'] or member.mode != expected[name]['mode']:
                raise ValueError('源码不属于本次候选：' + name)

def add_descriptions(item, version, notes_text, source_url):
    """Plain text, one per language: Sparkle shows the one matching the user's
    language, and as HTML (the default) every line break was lost."""
    lines = [l.strip() for l in notes_text.splitlines() if l.strip()]
    items = [l[1:].strip() for l in lines[1:] if l.startswith('·')]
    zh = [i for i in items if any('\u4e00' <= c <= '\u9fff' for c in i)]
    en = [i for i in items if i not in zh]
    if not lines or len(items) != len(lines) - 1 or not zh or not en or items != zh + en:
        raise ValueError('更新说明格式不对：标题行之后每行以“· ”开头，先中文条目、后英文条目')
    for language, title, entries, label in [('zh-Hans', '盘屿 ' + version, zh, '对应源码：'),
                                            ('en', 'Volisle ' + version, en, 'Source code: ')]:
        element = ET.SubElement(item, 'description', {'{'+SPARKLE+'}format': 'plain-text', XML_LANG: language})
        element.text = title + '\n\n' + '\n'.join('· ' + e for e in entries) + '\n\n' + label + source_url

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', required=True, type=Path)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--previous-feed', required=True, type=Path, help='从正式地址回读并保留的签名目录；首次发布使用当前空目录')
    parser.add_argument('--notes', required=True, type=Path, help='纯文本更新说明')
    parser.add_argument('--output-dir', required=True, type=Path, help='全新的待发布目录')
    args = parser.parse_args()
    if args.output_dir.exists(): parser.error('输出目录已存在，保留旧产物')
    app = args.candidate.resolve(strict=True)
    config = json.loads((ROOT/'config/updates.json').read_text())
    signing = json.loads((ROOT/'config/signing.json').read_text())
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    for key, value in [('CFBundleIdentifier',signing['bundle_id']),('SUPublicEDKey',config['public_ed25519_key']),
                       ('SUFeedURL',config['feed_url']),('SURequireSignedFeed',True),('SUVerifyUpdateBeforeExtraction',True)]:
        if info.get(key) != value: raise ValueError('发行候选配置不匹配：' + key)
    build = int(info['CFBundleVersion'])
    version = info['CFBundleShortVersionString']
    verify_readiness(json.loads((ROOT/'config/release-readiness.json').read_text()), build,
                     sha(app/'Contents/Resources/SourceProvenance.json'))
    run('codesign','--verify','--deep','--strict',app)
    details = subprocess.run(['codesign','-dvv',str(app)],capture_output=True,text=True,check=True).stderr
    if 'TeamIdentifier='+signing['team_id'] not in details.splitlines(): raise ValueError('发行团队不匹配')
    run('xcrun','stapler','validate',app)
    run('spctl','--assess','--type','execute','--verbose=2',app)
    verify_source(app,args.source)
    run(TOOLS/'sign_update','--account',ACCOUNT,'--verify',args.previous_feed)
    previous = ET.parse(args.previous_feed)
    versions = [int(x.text) for x in previous.findall('.//{'+SPARKLE+'}version')]
    if build <= max(versions,default=0): raise ValueError('构建号必须高于已发布的全部版本')
    public = run(TOOLS/'generate_keys','--account',ACCOUNT,'-p')
    if public != config['public_ed25519_key']: raise ValueError('钥匙串与候选公钥不匹配')
    args.output_dir.mkdir(parents=True)
    archive = args.output_dir/f'Volisle-{version}-{build}-universal.zip'
    run('ditto','-c','-k','--sequesterRsrc','--keepParent',app,archive)
    signature = run(TOOLS/'sign_update','--account',ACCOUNT,'-p',archive)
    if len(base64.b64decode(signature,validate=True)) != 64: raise ValueError('更新归档签名无效')
    run(TOOLS/'sign_update','--account',ACCOUNT,'--verify',archive,signature)
    source = args.output_dir/f'Volisle-{version}-{build}-source.tar.gz'
    shutil.copy2(args.source,source)
    base = config['feed_url'].rsplit('/',1)[0]+'/'
    ET.register_namespace('sparkle',SPARKLE)
    rss = ET.Element('rss',version='2.0'); channel = ET.SubElement(rss,'channel')
    ET.SubElement(channel,'title').text='盘屿正式版更新'
    ET.SubElement(channel,'link').text='https://qisw.top/volisle/'
    item=ET.SubElement(channel,'item')
    ET.SubElement(item,'title').text='盘屿 '+version
    ET.SubElement(item,'pubDate').text=format_datetime(datetime.now(timezone.utc))
    add_descriptions(item, version, args.notes.read_text(), base+source.name)
    ET.SubElement(item,'{'+SPARKLE+'}version').text=str(build)
    ET.SubElement(item,'{'+SPARKLE+'}shortVersionString').text=version
    ET.SubElement(item,'{'+SPARKLE+'}minimumSystemVersion').text=info['LSMinimumSystemVersion']
    ET.SubElement(item,'enclosure',{'url':base+archive.name,'length':str(archive.stat().st_size),'type':'application/octet-stream','{'+SPARKLE+'}edSignature':signature,'{'+SPARKLE+'}os':'macos'})
    feed=args.output_dir/'appcast.xml'
    ET.ElementTree(rss).write(feed,encoding='utf-8',xml_declaration=True)
    run(TOOLS/'sign_update','--account',ACCOUNT,feed)
    run(TOOLS/'sign_update','--account',ACCOUNT,'--verify',feed)
    (args.output_dir/'SHA256SUMS').write_text(''.join(sha(p)+'  '+p.name+'\n' for p in [archive,source,feed]))
    print('本地更新成品已生成并验签；尚未上传或公开发布：'+str(args.output_dir))

if __name__=='__main__': main()
