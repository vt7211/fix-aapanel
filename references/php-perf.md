# PHP / site slow after migrate (aaPanel)

## Symptom

Homepage TTFB **>5–15s** or timeouts right after moving a site to a new aaPanel VPS. XenForo and WordPress are both hit hard; lighter PHP apps less so.

## Root cause (most common)

**OPcache is off** on the PHP build used by the site. Fresh aaPanel PHP installs often ship with:

- `;zend_extension=opcache` commented out
- entire `[opcache]` block commented
- `memory_limit = 128M`
- PHP-FPM `pm.max_children = 150` (over-subscribe RAM under load)

Without OPcache, PHP recompiles every request → multi-second TTFB.

## Quick diagnose

```bash
# Which PHP does the site use?
rg -n 'php-cgi-|enable-php' /www/server/panel/vhost/nginx/<domain>.conf \
  /www/server/nginx/conf/enable-php*.conf 2>/dev/null | head

# Module present?
ls /www/server/php/*/lib/php/extensions/*/opcache.so

# CLI check (FPM may use php.ini; CLI may use php-cli.ini — check both)
for v in /www/server/php/*/bin/php; do
  echo "== $v =="; $v -m 2>/dev/null | rg -i opcache || echo 'NO OPcache'
  $v -i 2>/dev/null | rg -i '^(opcache\.enable|memory_limit)' || true
done

# Live FPM probe (delete after)
# echo '<?php echo extension_loaded("Zend OPcache")?"opc=on":"opc=off";' \
#   > /www/wwwroot/<site>/__opc.php && curl -sH 'Host: <domain>' http://127.0.0.1/__opc.php
```

Also check:

| Check | Bad default | Target |
|---|---|---|
| OPcache | Off | On; PHP 8+ + JIT |
| `memory_limit` | 128M | 512M (XF/WP) |
| InnoDB buffer | ~1G or tiny | ~25–40% RAM (e.g. 4G on 16G host) |
| Query cache | On | **Off** (often harmful) |
| PHP-FPM `max_children` | 150 | ~50 + `pm.max_requests=500` |
| Nginx | no file cache | `open_file_cache` + bump existing `fastcgi_buffers` in-place |

**Nginx caution:** aaPanel `proxy.conf` already sets `client_body_buffer_size`. Do not redeclare it in `nginx.conf` or `nginx -t` fails with duplicate directive. Only add `open_file_cache*` and raise existing `fastcgi_buffers` / `fastcgi_buffer_size`.
| Redis | `maxmemory 0` | Cap + `allkeys-lru` if used for cache |

## Fix (all PHP versions on the box)

Prefer the skill script (idempotent, backs up `*.perf.bak`):

```bash
# From skill repo on the server, as root:
bash scripts/optimize_php_perf.sh --with-mysql --with-redis --with-nginx

# Or one version only:
bash scripts/optimize_php_perf.sh --php 83
```

Install path if you copy scripts permanently:

```bash
install -m 700 scripts/optimize_php_perf.sh /www/server/panel/script/optimize_php_perf.sh
```

### Proven OPcache targets (post-migrate XenForo, PHP 8.3)

```
opcache.enable=1
opcache.memory_consumption=256
opcache.max_accelerated_files=50000
opcache.revalidate_freq=60
opcache.jit=1255
opcache.jit_buffer_size=128M
memory_limit=512M
```

- **PHP 7.4**: same OPcache knobs, **no JIT** (script skips JIT automatically).
- **PHP 8.0–8.4**: enable JIT as above unless you have a reason not to.
- Apply to **every** `/www/server/php/<ver>/etc/php.ini` (and `php-cli.ini` if present) so a site PHP switch does not reintroduce the outage.

### PHP-FPM

```
pm.max_children = 50
pm.start_servers = 10
pm.min_spare_servers = 5
pm.max_spare_servers = 20
pm.max_requests = 500
```

Lower `max_children` on small RAM hosts (rule of thumb: children × ~40–80MB < available RAM after MySQL/Redis).

Restart FPM after edits (`/etc/init.d/php-fpm-83 restart` or `systemctl restart php-fpm-83`).

## App-layer (do after OPcache — platform specific)

### XenForo

- Redis: enable cache + sessions (`SV\RedisCache` or equivalent); Redis `maxmemory` capped, `allkeys-lru`
- Page cache for `/`, `/forums/`, `/threads/` when safe
- Static browser cache ~30d for `/data/`, `/js/`, `/styles/`, images/css/fonts
- Prefer PHP 8.2/8.3 + current XF patch level
- Cloudflare: **Full (strict)** SSL, not Flexible — Flexible causes `ERR_TOO_MANY_REDIRECTS`. Nginx must trust `X-Forwarded-Proto` if origin is HTTP behind CF

### WordPress

Same **server** stack (OPcache/JIT, memory, FPM, InnoDB, nginx buffers). Then:

- Object cache: Redis Object Cache / similar when Redis is available
- Page cache: nginx fastcgi_cache or a WP page-cache plugin — do not stack conflicting page caches
- Avoid enabling MySQL query cache “for WordPress”
- Same Cloudflare Full SSL / `X-Forwarded-Proto` rule

### Other PHP apps (Laravel, custom)

OPcache + sensible `memory_limit` + FPM caps still apply. Framework caches (`php artisan config:cache`, etc.) are separate and optional.

## Cloudflare redirect loop

```
Flexible SSL → browser HTTPS → origin HTTP → app redirects to HTTPS → loop
```

Fix: Cloudflare SSL mode **Full** or **Full (strict)** with a valid origin cert (aaPanel LE is fine). Optionally in PHP/nginx set HTTPS detection from `X-Forwarded-Proto`.

## Verify

```bash
# Local TTFB after warm OPcache (expect ~1s class for heavy XF, often lower for WP)
curl -o /dev/null -s -w 'TTFB:%{time_starttransfer}\n' -H 'Host: <domain>' \
  'http://127.0.0.1/index.php'

# Confirm OPcache from FPM (not only CLI)
```

Target after this playbook (heavy XenForo, local): homepage TTFB about **0.9–1.4s**. Cold first hit can be slower until OPcache fills.

## Hard rules

1. **Fix OPcache first** before chasing plugins, CDN, or rewriting queries.
2. **Do not leave query cache on** as a “speed” fix on modern MariaDB/MySQL.
3. **Do not set FPM max_children=150** on a 4–8G box — it OOMs and looks like “slowness”.
4. Re-run `optimize_php_perf.sh` after installing a **new** PHP version in aaPanel.
5. Never paste Redis/MySQL passwords or panel paths into chat logs.
