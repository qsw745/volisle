#!/usr/bin/env python3
"""Only a validated, signed HTTPS feed can enable the shipping updater."""
import base64
import json
from pathlib import Path
import plistlib
import re
import sys
from urllib.parse import urlsplit
ROOT = Path(__file__).resolve().parents[1]

def configure(info, config):
    if config.get('schema') != 1 or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}', config.get('version', '')) or type(config.get('build')) is not int or config['build'] < 1:
        raise ValueError('更新版本配置无效')
    info = dict(info, CFBundleShortVersionString=config['version'], CFBundleVersion=str(config['build']))
    for name in ['SUFeedURL', 'SUPublicEDKey', 'SUEnableAutomaticChecks', 'SUAutomaticallyUpdate', 'SURequireSignedFeed', 'SUVerifyUpdateBeforeExtraction']:
        info.pop(name, None)
    if config.get('channel') == 'unconfigured':
        if config.get('feed_url') is not None or config.get('public_ed25519_key') is not None:
            raise ValueError('未开放的通道不能带更新地址或密钥')
    elif config.get('channel') == 'website':
        feed, key = config.get('feed_url', ''), config.get('public_ed25519_key', '')
        parts = urlsplit(feed)
        if parts.scheme != 'https' or not parts.hostname or parts.username or parts.password or parts.query or parts.fragment:
            raise ValueError('更新源必须是不带凭据的 HTTPS 地址')
        decoded = base64.b64decode(key, validate=True)
        if len(decoded) != 32 or not any(decoded): raise ValueError('Ed25519 公钥无效')
        info.update(SUFeedURL=feed, SUPublicEDKey=key, SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=False,
                    SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True, SUSendProfileInfo=False, SUScheduledCheckInterval=86400)
    else: raise ValueError('不支持的更新通道')
    return info

if __name__ == '__main__':
    target = Path(sys.argv[1]) / 'Contents/Info.plist'
    target.write_bytes(plistlib.dumps(configure(plistlib.loads(target.read_bytes()), json.loads((ROOT/'config/updates.json').read_text()))))
