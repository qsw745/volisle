#!/usr/bin/env python3
"""Generate the Traditional Chinese tables from the Simplified ones.

OpenCC's s2twp (Taiwan vocabulary) does the conversion; TERMS then align it
with what Taiwan's macOS itself calls things, so the instructions match the
screens the user sees. Order matters: every 退出 in the source means quitting
or ending (結束), every 推出 means ejecting (退出 on Taiwan's macOS).

Needs the opencc package, e.g. in a throwaway environment:
  python3 -m venv /tmp/opencc && /tmp/opencc/bin/pip install opencc
  /tmp/opencc/bin/python scripts/make-zh-hant.py
then run scripts/check-localization.py.
"""
import re
from pathlib import Path

import opencc

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'assets/brand/Localization/app'

TERMS = [
    ('退出', '結束'), ('推出', '退出'),
    ('只讀', '唯讀'),
    ('→ 通用 →', '→ 一般 →'),
    ('登錄項與擴充套件', '登入項目與延伸功能'), ('登錄項與擴充功能', '登入項目與延伸功能'), ('登錄項與擴展', '登入項目與延伸功能'),
    ('檔案系統擴充套件', '檔案系統延伸功能'), ('檔案系統擴充功能', '檔案系統延伸功能'), ('檔案系統擴展', '檔案系統延伸功能'),
    ('擴充套件', '延伸功能'), ('擴充功能', '延伸功能'), ('擴展', '延伸功能'),
    ('隱私與安全性', '隱私權與安全性'), ('完全磁碟訪問', '完整磁碟取用權限'), ('完全磁碟存取', '完整磁碟取用權限'),
    ('移動硬碟', '外接硬碟'), ('行動硬碟', '外接硬碟'),
    ('分割槽', '分割區'), ('分區', '分割區'),
    ('抹掉', '清除'),
    # 卸载 a disk is 卸載; only uninstalling Volisle itself is 解除安裝.
    ('解除安裝(?!盤嶼)', '卸載'),
    ('在訪達中', '在 Finder 中'), ('訪達', 'Finder'),
    ('磁碟工具(?!程式)', '磁碟工具程式'),
    ('盤嶼幫助', '盤嶼輔助說明'), ('獲得幫助', '取得協助'), ('需要幫助', '需要協助'),
    ('卷名', '卷宗名稱'), ('卷(?!宗)', '卷宗'),
    ('登錄時', '登入時'), ('登錄啟動', '登入時啟動'), ('登入項與', '登入項目與'),
    (' ?U ?盤', '隨身碟'),
    ('許可權', '權限'), ('後臺', '背景'), ('訪問', '取用'), ('雷靂', 'Thunderbolt'), ('專案', '項目'),
    ('啟動臺', '啟動台'), ('選單欄', '選單列'),
    # 块 is only ever the measure word for a disk: Taiwan says 個磁碟.
    ('塊盤', '個磁碟'), ('塊磁碟', '個磁碟'), ('塊', '個'),
    # A disk on its own (盤上, 把盤…) is 磁碟; copying is 複製.
    ('(?<![磁硬光])盤(?!嶼)', '磁碟'), ('拷貝', '複製'), ('拷', '複製'),
    # Taiwan's quotation marks.
    ('“', '「'), ('”', '」'),
]
# Whole strings that read better rewritten than converted.
WHOLE = {'通用': '一般'}

STRING = re.compile(r'^"((?:[^"\\]|\\.)*)" = "((?:[^"\\]|\\.)*)";', re.M)


def convert(converter, text):
    if text in WHOLE:
        return WHOLE[text]
    out = converter.convert(text)
    for pattern, replacement in TERMS:
        out = re.sub(pattern, replacement, out)
    # Placeholders are never converted; keep them exactly as in the key.
    return out


def main():
    converter = opencc.OpenCC('s2twp')
    keys = [m.group(1) for m in STRING.finditer((APP / 'zh-Hans.lproj/Localizable.strings').read_text(encoding='utf-8'))]
    body = ['/* 繁體中文：由 scripts/make-zh-hant.py 依簡體原文轉換（OpenCC s2twp 加台灣 macOS 用語），鍵為簡體原文。 */', '']
    for key in keys:
        value = convert(converter, key)
        assert re.findall(r'%(?:\d\$)?[@d]|%lld', value) == re.findall(r'%(?:\d\$)?[@d]|%lld', key), key
        body.append(f'"{key}" = "{value}";')
    (APP / 'zh-Hant.lproj').mkdir(exist_ok=True)
    (APP / 'zh-Hant.lproj/Localizable.strings').write_text('\n'.join(body) + '\n', encoding='utf-8')
    info = (APP / 'zh-Hans.lproj/InfoPlist.strings').read_text(encoding='utf-8')
    converted = STRING.sub(lambda m: f'"{m.group(1)}" = "{convert(converter, m.group(2))}";', info)
    (APP / 'zh-Hant.lproj/InfoPlist.strings').write_text(converter.convert(converted.split('\n', 1)[0]) + '\n' + converted.split('\n', 1)[1], encoding='utf-8')
    print(f'繁體中文：{len(keys)} 條')


if __name__ == '__main__':
    main()
