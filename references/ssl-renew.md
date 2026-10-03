# Virtual Host site SSL renew

## Architecture

| Piece | Path / note |
|---|---|
| Live nginx cert | `/www/server/vhost_virtual/vhost/nginx/<domain>/certificate.pem` |
| Live key | `.../private_key.pem` |
| Site configs | `vhost.conf` + `ssl_verify.conf` (both need ACME fix) |
| Metadata | `ssl.sqlite` (`letsencrypts`, `renew_logs`), `website.sqlite` (`sites`) |
| Native renewer | Inside `vhost_virtual` (~every 2h), **not** panel `acme_v2 --renew_v3` |
| Shared webroot | `/www/wwwroot/acme_webroot/.well-known/acme-challenge/` |

Document roots are usually `/home/<account>/wwwroot/<domain>`.

## Diagnose

```bash
# Live handshake
echo | openssl s_client -servername DOMAIN -connect 127.0.0.1:443 2>/dev/null \
  | openssl x509 -noout -dates -issuer

# Disk cert
openssl x509 -noout -dates -issuer -in \
  /www/server/vhost_virtual/vhost/nginx/DOMAIN/certificate.pem

# Renew history
sqlite3 /www/server/vhost_virtual/data/db/ssl.sqlite \
  "SELECT renew_id, cert_id, status, datetime(renew_time,'unixepoch','+7 hours'),
          substr(error_info,1,180)
   FROM renew_logs ORDER BY renew_id DESC LIMIT 20;"

# Metadata the renewer trusts
sqlite3 /www/server/vhost_virtual/data/db/ssl.sqlite \
  "SELECT cert_id, subject, issuer, not_after, endtime, status FROM letsencrypts;"
sqlite3 /www/server/vhost_virtual/data/db/website.sqlite \
  "SELECT site_id, site_name, cert_id, ssl_expire, force_https FROM sites;"
```

Corrupt metadata signals:

- `issuer` = `YR1` / `YR2` (intermediate CN) instead of `Let's Encrypt`
- `endtime` tiny (e.g. `89`) instead of unix `notAfter`
- DB `certificate` older than file on disk

## Required hybrid ACME block

Apply to **both** `vhost.conf` and `ssl_verify.conf`. Use `scripts/patch_acme_hybrid.sh`.

```nginx
location ^~ /.well-known/acme-challenge/ {
    default_type text/plain;
    root /www/wwwroot/acme_webroot;
    try_files $uri @acme_vhost;
    allow all;
    error_page 404 =404;
}
location @acme_vhost {
    proxy_pass http://127.0.0.1:60880;
    proxy_set_header Host $host;
    proxy_intercept_errors off;
}
```

Why:

- `^~` beats later regex locations
- File hit → webroot (maintain job / manual `acme_v2`)
- Miss → proxy 60880 (native Virtual Host renew; port only up during challenge)
- `error_page 404 =404` stops missing token → internal `/404.html` → force-HTTPS → LE error `https://domain/404.html`
- Keep server-level `if ( $uri ~ /\.well-known/ )` so force-HTTPS skips challenges

After edit: `nginx -t && nginx -s reload`.

### Prove webroot path

```bash
mkdir -p /www/wwwroot/acme_webroot/.well-known/acme-challenge
echo ok > /www/wwwroot/acme_webroot/.well-known/acme-challenge/pingtest
chown -R www:www /www/wwwroot/acme_webroot
curl -s --resolve DOMAIN:80:127.0.0.1 http://DOMAIN/.well-known/acme-challenge/pingtest
rm -f /www/wwwroot/acme_webroot/.well-known/acme-challenge/pingtest
```

Expect body `ok`. `301` / `404.html` = location lost the race.

### Anti-pattern (do not repeat)

Replacing ACME with **webroot-only** (removing 60880) looks correct when 60880 is idle, then breaks native renew forever.

## Issue / renew a cert (panel ACME)

One site at a time. Do not burn LE rate limits with force renew on healthy certs.

```bash
/www/server/panel/pyenv/bin/python3 - << 'PY'
import os, sys
os.chdir("/www/server/panel")
sys.path[:0] = ["/www/server/panel", "/www/server/panel/class"]
from acme_v2 import acme_v2
domains = ["example.vn", "www.example.vn"]  # change
res = acme_v2().apply_cert(domains, "http", "/www/wwwroot/acme_webroot")
print(res.get("status"), res.get("msg"))
if res.get("status"):
    open("/tmp/example.fullchain.pem","w").write(res["cert"] + res.get("root",""))
    open("/tmp/example.key.pem","w").write(res["private_key"])
PY
```

Install:

1. Modulus-match cert/key
2. Backup `certificate.pem` / `private_key.pem` with `.bak.<stamp>`
3. Write **leaf + chain** to `certificate.pem` (`chmod 644`), key `chmod 600`
4. Repair SQLite metadata (below)
5. `nginx -t && nginx -s reload`
6. Verify `openssl s_client`; delete `/tmp/*.key.pem`

## Repair metadata

```bash
# Pseudocode — use vhost_ssl_maintain.py in practice
# issuer='Let'\''s Encrypt'
# not_after='YYYY-MM-DD'
# endtime=<openssl notAfter unix>
# certificate/private_key = file contents
# sites.ssl_expire = same unix
```

Prefer running:

```bash
/www/server/panel/pyenv/bin/python3 /www/server/panel/script/vhost_ssl_maintain.py
```

## Prevent recurrence

```cron
20 4 * * * /www/server/panel/pyenv/bin/python3 /www/server/panel/script/vhost_ssl_maintain.py >> /www/server/panel/logs/vhost_ssl_maintain.log 2>&1
```

Renews when ≤ **20 days** left; always repairs issuer/endtime/PEM drift. Operator request “renew 20–30 days early” → keep threshold in that window (script default 20; set `RENEW_WITHIN_SECONDS` if customized).

Site rebuild in panel may restore stock `proxy_pass 60880` only — re-run `patch_acme_hybrid.sh`.
