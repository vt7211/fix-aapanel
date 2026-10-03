# Hardening & install on a fresh aaPanel host

## Daily SSL schedule (recommended)

| Time | Job |
|---|---|
| ~05:54 (panel default) | `acme_v2.py --renew_v3` — classic panel + panel UI cert |
| `20 4 * * *` | `vhost_ssl_maintain.py` — VH site metadata + early renew (≤20d) |
| `10 6 * * *` | `sync_vhost_ssl.sh` — panel UI cert → port 57001 |

Adjust times if the host’s panel renew cron differs (`crontab -l | rg acme`).

## Install sync (port 57001)

```bash
install -m 700 scripts/sync_vhost_ssl.sh /www/server/panel/script/sync_vhost_ssl.sh

cat >/www/server/cron/sync_vhost_ssl <<'EOF'
#!/bin/bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH
/bin/bash /www/server/panel/script/sync_vhost_ssl.sh
EOF
chmod 700 /www/server/cron/sync_vhost_ssl

(crontab -l 2>/dev/null | grep -v sync_vhost_ssl; \
  echo '10 6 * * *  /www/server/cron/sync_vhost_ssl >> /www/server/cron/sync_vhost_ssl.log 2>&1') | crontab -

bash /www/server/panel/script/sync_vhost_ssl.sh
```

Log: `/www/server/panel/logs/sync_vhost_ssl.log`

## Install Virtual Host maintain

```bash
install -m 700 scripts/vhost_ssl_maintain.py /www/server/panel/script/vhost_ssl_maintain.py
mkdir -p /www/wwwroot/acme_webroot/.well-known/acme-challenge
chown -R www:www /www/wwwroot/acme_webroot

bash scripts/patch_acme_hybrid.sh
nginx -t && nginx -s reload

(crontab -l 2>/dev/null | grep -v vhost_ssl_maintain; \
  echo '20 4 * * * /www/server/panel/pyenv/bin/python3 /www/server/panel/script/vhost_ssl_maintain.py >> /www/server/panel/logs/vhost_ssl_maintain.log 2>&1') | crontab -

/www/server/panel/pyenv/bin/python3 /www/server/panel/script/vhost_ssl_maintain.py
```

Log: `/www/server/panel/logs/vhost_ssl_maintain.log`

## After every Virtual Host site rebuild

Panel may rewrite nginx to stock `proxy_pass 60880` only. Re-run:

```bash
bash /path/to/fix-aapanel/scripts/patch_acme_hybrid.sh
nginx -t && nginx -s reload
```

## PHP performance (run once per host / after new PHP version)

Fresh aaPanel PHP installs often leave **OPcache disabled** → XenForo/WordPress TTFB 15s+ after migrate. Prevent that:

```bash
install -m 700 scripts/optimize_php_perf.sh /www/server/panel/script/optimize_php_perf.sh
bash /www/server/panel/script/optimize_php_perf.sh --with-mysql --with-redis --with-nginx
```

Details + XenForo/WordPress app-layer notes: [php-perf.md](php-perf.md).

## Ops hygiene

- Keep ≥15% free disk on `/`
- Do not expose panel ports through Cloudflare orange cloud
- Prefer DNS-only + firewall allowlist for panel ports
- After LE issue, delete temp keys under `/tmp`
- Never commit real `admin_path`, passwords, or private keys into this skill repo
- After installing a new PHP version in the panel, re-run `optimize_php_perf.sh` (OPcache starts commented out again)
- Cloudflare SSL: Full/strict for proxied sites — Flexible causes HTTPS redirect loops
