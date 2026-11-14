#!/bin/sh
# Serves the landing page in site/ at http://localhost:8791 until Ctrl-C.
set -eu
cd "$(dirname "$0")/../site"
echo "mx site: http://localhost:8791"
exec python3 -m http.server 8791 --bind 127.0.0.1
