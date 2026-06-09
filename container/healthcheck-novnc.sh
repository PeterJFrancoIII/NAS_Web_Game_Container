#!/bin/sh
set -eu

TLS_CERT="${TLS_CERT:-/opt/ra2/tls/cert.pem}"
TLS_KEY="${TLS_KEY:-/opt/ra2/tls/key.pem}"

if [ -f "$TLS_CERT" ] && [ -f "$TLS_KEY" ]; then
  python -c "
import ssl
import urllib.request

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
urllib.request.urlopen('https://127.0.0.1:6080/', context=ctx, timeout=5)
"
else
  python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:6080/', timeout=5)"
fi
