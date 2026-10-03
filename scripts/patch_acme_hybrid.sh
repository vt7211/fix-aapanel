#!/bin/bash
# Restore hybrid ACME challenge blocks on all Virtual Host nginx configs.
# Safe to re-run. Backs up each file once as *.acmehybrid.bak

set -euo pipefail

WEBROOT="${WEBROOT:-/www/wwwroot/acme_webroot}"
NGINX_ROOT="${NGINX_ROOT:-/www/server/vhost_virtual/vhost/nginx}"

mkdir -p "$WEBROOT/.well-known/acme-challenge"
chown -R www:www "$WEBROOT" 2>/dev/null || true
chmod -R a+rX "$WEBROOT" 2>/dev/null || true

python3 - "$NGINX_ROOT" <<'PY'
import os, re, sys

root = sys.argv[1]
block = """\tlocation ^~ /.well-known/acme-challenge/ {
\t\tdefault_type text/plain;
\t\troot /www/wwwroot/acme_webroot;
\t\ttry_files $uri @acme_vhost;
\t\tallow all;
\t\terror_page 404 =404;
\t}
\tlocation @acme_vhost {
\t\tproxy_pass http://127.0.0.1:60880;
\t\tproxy_set_header Host $host;
\t\tproxy_intercept_errors off;
\t}"""

# Match stock proxy-only OR prior webroot-only OR already-hybrid (idempotent replace of challenge locs)
pat = re.compile(
    r"location\s+(?:\^~\s+)?~?\s*\^?/\\?\.well-known/acme-challenge/[^{]*\{[\s\S]*?\n\t\}"
    r"(?:\s*location\s+@acme_vhost\s*\{[\s\S]*?\n\t\})?",
    re.M,
)

# Also match stock without ^~
pat2 = re.compile(
    r"location\s+~\s+\^/\\.well-known/acme-challenge/\s*\{[^}]*proxy_pass\s+http://127\.0\.0\.1:60880;[^}]*\}",
    re.M,
)

changed = 0
for dirpath, _, files in os.walk(root):
    for name in files:
        if name not in ("vhost.conf", "ssl_verify.conf"):
            continue
        path = os.path.join(dirpath, name)
        with open(path, encoding="utf-8", errors="ignore") as fh:
            text = fh.read()
        if "try_files $uri @acme_vhost" in text and "error_page 404 =404" in text and "@acme_vhost" in text:
            # already good
            continue
        bak = path + ".acmehybrid.bak"
        if not os.path.exists(bak):
            open(bak, "w", encoding="utf-8").write(text)
        new, n = pat2.subn(block, text, count=1)
        if n == 0:
            new, n = pat.subn(block, text, count=1)
        if n == 0 and "acme-challenge" in text:
            # last resort: replace from first acme-challenge location through its closing brace
            new, n = re.subn(
                r"location[^\n]*acme-challenge[^\n]*\{[\s\S]*?\n\t\}(?:\s*location\s+@acme_vhost\s*\{[\s\S]*?\n\t\})?",
                block,
                text,
                count=1,
            )
        if n and new != text:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(new)
            print("patched", path)
            changed += 1
        else:
            print("skip", path)

print("done, changed=", changed)
PY

echo "Run: nginx -t && nginx -s reload"
