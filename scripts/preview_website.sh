#!/bin/bash
set -eo pipefail

CDPATH= cd "$(dirname "$0")/.."

WEBSITE_DIR="website"

if [ ! -d "$WEBSITE_DIR" ]; then
    echo "❌ 未找到 website 目录！"
    exit 1
fi

PORT=${1:-8000}

python3 - "$PORT" "$WEBSITE_DIR" << 'EOF'
import http.server
import socketserver
import os
import sys
import webbrowser

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
directory = sys.argv[2] if len(sys.argv) > 2 else "website"

if not os.path.exists(directory):
    print(f"❌ 目录不存在: {directory}")
    sys.exit(1)

os.chdir(directory)

class DualStackServer(socketserver.TCPServer):
    allow_reuse_address = True

Handler = http.server.SimpleHTTPRequestHandler

while True:
    try:
        httpd = DualStackServer(("", port), Handler)
        break
    except OSError as e:
        if e.errno in (48, 98):  # Address already in use
            port += 1
        else:
            raise e

url = f"http://localhost:{port}"
print(f"🚀 正在启动 website 静态服务器...")
print(f"📍 预览地址: {url}")
print(f"📂 网站目录: {os.getcwd()}")
print(f"💡 按 Ctrl+C 可关闭服务器", flush=True)

try:
    webbrowser.open(url)
except Exception:
    pass

try:
    httpd.serve_forever()
except KeyboardInterrupt:
    print("\n🛑 服务器已关闭")
EOF
