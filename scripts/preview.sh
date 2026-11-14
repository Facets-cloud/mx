#!/bin/sh
# Serves the landing page in site/ at http://localhost:8791 until Ctrl-C.
# Answers Range requests so the video players can seek (python's
# http.server alone always sends the whole file, which breaks seeking).
set -eu
cd "$(dirname "$0")/../site"
echo "mx site: http://localhost:8791"
exec python3 - <<'EOF'
import http.server, os, re

class Handler(http.server.SimpleHTTPRequestHandler):
    def send_head(self):
        m = re.fullmatch(r"bytes=(\d*)-(\d*)", self.headers.get("Range", ""))
        path = self.translate_path(self.path)
        if not m or not os.path.isfile(path):
            return super().send_head()
        size = os.path.getsize(path)
        start, end = m.groups()
        if start:
            start, end = int(start), min(int(end) if end else size - 1, size - 1)
        else:
            start, end = max(size - int(end), 0), size - 1
        if start > end:
            self.send_error(416)
            return None
        f = open(path, "rb")
        f.seek(start)
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        self.remaining = end - start + 1
        return f

    def copyfile(self, src, dst):
        n = getattr(self, "remaining", None)
        if n is None:
            return super().copyfile(src, dst)
        while n > 0:
            chunk = src.read(min(64 * 1024, n))
            if not chunk:
                break
            dst.write(chunk)
            n -= len(chunk)

http.server.ThreadingHTTPServer(("127.0.0.1", 8791), Handler).serve_forever()
EOF
