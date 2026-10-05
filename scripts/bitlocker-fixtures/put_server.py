#!/usr/bin/env python3
"""Receives the VM's uploads (PUT /<name>) into a directory. Listens only on the
Parallels shared-network host address; plain names, at most 400 MB each."""
import http.server
import os
import re
import sys

ROOT = sys.argv[1]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_PUT(self):
        name = os.path.basename(self.path)
        length = int(self.headers.get('Content-Length', '0'))
        if not re.fullmatch(r'[A-Za-z0-9._-]{1,64}', name) or length > 400 << 20:
            self.send_response(400); self.end_headers(); return
        with open(os.path.join(ROOT, name), 'wb') as f:
            left = length
            while left:
                chunk = self.rfile.read(min(left, 1 << 20))
                if not chunk:
                    break
                f.write(chunk); left -= len(chunk)
        self.send_response(201); self.end_headers()


http.server.HTTPServer(('10.211.55.2', 8766), Handler).serve_forever()
