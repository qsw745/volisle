#!/usr/bin/env python3
"""仅监听本机；从静态导出目录服务，缺失页面使用产品 404。"""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1] / 'apps/web/out'
class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs): super().__init__(*args, directory=str(ROOT), **kwargs)
    def send_error(self, code, message=None, explain=None):
        if code == 404:
            data=(ROOT/'404.html').read_bytes()
            self.send_response(404); self.send_header('Content-Type','text/html; charset=utf-8')
            self.send_header('Content-Length',str(len(data))); self.end_headers()
            if self.command!='HEAD': self.wfile.write(data)
        else: super().send_error(code,message,explain)
print('盘屿官网预览：http://127.0.0.1:4317/',flush=True)
ThreadingHTTPServer(('127.0.0.1',4317),Handler).serve_forever()
