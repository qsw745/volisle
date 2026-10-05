#!/usr/bin/env python3
"""检查实际静态产物的标题、元信息与内部链接；不替代浏览器验证。"""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit, unquote
import json
import re
root = Path(__file__).resolve().parents[1]
out = root / 'apps/web/out'
release_ts = (root / 'apps/web/lib/release.ts').read_text()
published = re.search(r"published:\s*true", release_ts) is not None
packages = {re.search(rf"{key}:\s*'([^']+)'", release_ts).group(1) for key in ('dmg', 'source')}
# Earlier versions listed on the download page (apps/web/lib/history.ts).
history_ts = (root / 'apps/web/lib/history.ts').read_text()
packages |= set(re.findall(r"(?:dmg|source): '(/downloads/[^']+)'", history_ts))
base = '/volisle'
class Document(HTMLParser):
    def __init__(self):
        super().__init__(); self.links=[]; self.ids=set(); self.headings=0; self.title=False; self.description=False; self.noindex=False; self.lang=None; self.canonical=None; self.hreflang={}; self.switch=None
    def handle_starttag(self, tag, pairs):
        a=dict(pairs)
        if 'id' in a: self.ids.add(a['id'])
        if tag=='html': self.lang=a.get('lang')
        if tag=='link' and a.get('rel')=='canonical': self.canonical=a.get('href')
        if tag=='link' and a.get('rel')=='alternate' and a.get('hreflang'): self.hreflang[a['hreflang']]=a.get('href')
        if tag=='a' and 'language-switch' in a.get('class','').split(): self.switch=a.get('href')
        if tag=='a' and 'href' in a: self.links.append(a['href'])
        if tag=='h1': self.headings+=1
        if tag=='title': self.title=True
        if tag=='meta' and a.get('name')=='description': self.description=True
        if tag=='meta' and a.get('name')=='robots' and 'noindex' in a.get('content',''): self.noindex=True
site='https://qisw.top/volisle'
names=['','download','compatibility','help','changelog','privacy','terms','support','sitemap']
pages=names+['en/'+n if n else 'en' for n in names]
parsed={}
for page in pages:
    path=out / page / 'index.html'
    d=Document(); d.feed(path.read_text()); parsed['/'+page+('/' if page else '')]=d
    assert d.headings==1 and d.title and d.description, f'元信息不完整：{page}'
    assert d.noindex != published, f'索引设置与发布状态不符：{page}'
    english=page=='en' or page.startswith('en/')
    zh_path='/'+(page[3:] if page.startswith('en/') else '' if page=='en' else page)
    zh_path=zh_path if zh_path=='/' else zh_path+'/'
    en_path='/en'+zh_path
    own, other = (en_path, zh_path) if english else (zh_path, en_path)
    assert d.lang==('en' if english else 'zh-CN'), f'html lang 不符：{page} {d.lang}'
    assert d.canonical==site+own, f'规范地址不符：{page} {d.canonical}'
    assert d.hreflang.get('zh-CN')==site+zh_path and d.hreflang.get('en')==site+en_path and d.hreflang.get('x-default')==site+zh_path, f'语言互指不符：{page} {d.hreflang}'
    assert d.switch==base+other, f'语言切换链接不符：{page} {d.switch}'
links=0
downloads=set()
for route, d in parsed.items():
    for href in d.links:
        u=urlsplit(href)
        if u.scheme or u.netloc: continue
        destination=unquote(u.path) or route
        if destination.startswith(base + '/'): destination=destination[len(base):]
        if destination.endswith(('.dmg','.pkg','.zip','.tar.gz')):
            assert published, '无包时不应有下载链接'
            assert destination in packages, f'下载链接与发布配置不符：{href}'
            downloads.add(destination); links+=1
            continue
        target=out / destination.lstrip('/')
        if not target.suffix: target=target / 'index.html'
        assert target.exists(), f'坏链接：{route} -> {href}'
        if u.fragment and destination in parsed:
            assert u.fragment in parsed[destination].ids, f'锚点缺失：{href}'
        links+=1
assert (out/'404.html').exists()
assert downloads == (packages if published else set()), f'下载链接不完整：{downloads}'
report={'pages':len(pages),'languages':['zh-CN','en'],'links_checked':links,'metadata':'通过','published':published,'download_links':sorted(downloads),'404_artifact':'存在','scope':'静态产物校验；不是浏览器或性能测试'}
(root/'docs/testing/web-static-result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(report,ensure_ascii=False))
