#!/bin/bash
# Enable OPcache (+ JIT on PHP 8+) and apply post-migrate PHP/FPM defaults
# on every aaPanel PHP install under /www/server/php/<ver>.
# Idempotent. Safe defaults proven after XenForo migrate (TTFB 15s+ → ~1s).
#
# Usage:
#   bash optimize_php_perf.sh              # all PHP versions
#   bash optimize_php_perf.sh --php 83     # one version only
#   bash optimize_php_perf.sh --dry-run
#   bash optimize_php_perf.sh --with-mysql --with-redis --with-nginx

set -euo pipefail

DRY_RUN=0
ONLY_VER=""
WITH_MYSQL=0
WITH_REDIS=0
WITH_NGINX=0

# Tunables (override via env)
MEMORY_LIMIT="${MEMORY_LIMIT:-512M}"
OPCACHE_MEM="${OPCACHE_MEM:-256}"
OPCACHE_FILES="${OPCACHE_FILES:-50000}"
OPCACHE_REVALIDATE="${OPCACHE_REVALIDATE:-60}"
OPCACHE_INTERNED="${OPCACHE_INTERNED:-16}"
JIT_MODE="${JIT_MODE:-1255}"
JIT_BUFFER="${JIT_BUFFER:-128M}"
FPM_MAX_CHILDREN="${FPM_MAX_CHILDREN:-50}"
FPM_START="${FPM_START:-10}"
FPM_MIN_SPARE="${FPM_MIN_SPARE:-5}"
FPM_MAX_SPARE="${FPM_MAX_SPARE:-20}"
FPM_MAX_REQUESTS="${FPM_MAX_REQUESTS:-500}"
INNODB_BUFFER="${INNODB_BUFFER:-4G}"
REDIS_MAXMEMORY="${REDIS_MAXMEMORY:-2gb}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --php) ONLY_VER="${2:-}"; shift 2 ;;
    --with-mysql) WITH_MYSQL=1; shift ;;
    --with-redis) WITH_REDIS=1; shift ;;
    --with-nginx) WITH_NGINX=1; shift ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] $*"
  else
    eval "$@"
  fi
}

backup_once() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  if [[ ! -f "${f}.perf.bak" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[dry-run] cp -a $f ${f}.perf.bak"
    else
      cp -a "$f" "${f}.perf.bak"
    fi
  fi
}

php_major_minor() {
  # path .../php/83/... → 8.3 ; 74 → 7.4
  local ver="$1"
  if [[ ${#ver} -eq 2 ]]; then
    echo "${ver:0:1}.${ver:1:1}"
  else
    echo "$ver"
  fi
}

supports_jit() {
  # JIT exists from PHP 8.0+
  local mm
  mm=$(php_major_minor "$1")
  awk -v v="$mm" 'BEGIN{exit !(v+0 >= 8.0)}'
}

patch_php_ini() {
  local ini="$1" ver="$2" so="$3"
  [[ -f "$ini" ]] || return 0
  backup_once "$ini"

  python3 - "$ini" "$ver" "$so" "$MEMORY_LIMIT" "$OPCACHE_MEM" "$OPCACHE_FILES" \
    "$OPCACHE_REVALIDATE" "$OPCACHE_INTERNED" "$JIT_MODE" "$JIT_BUFFER" "$DRY_RUN" <<'PY'
import re, sys
path, ver, so, mem_limit, opc_mem, opc_files, reval, interned, jit, jit_buf, dry = sys.argv[1:]
dry = dry == "1"
text = open(path, encoding="utf-8", errors="ignore").read()
orig = text

def set_or_add(text, key, value, section=None):
    # Uncomment / replace existing key; else append under section or end
    pat = re.compile(rf"(?m)^[; ]*{re.escape(key)}\s*=\s*.*$")
    line = f"{key} = {value}"
    if pat.search(text):
        return pat.sub(line, text, count=1)
    if section:
        sp = re.compile(rf"(?m)^\[{re.escape(section)}\]\s*$")
        m = sp.search(text)
        if m:
            i = m.end()
            return text[:i] + "\n" + line + text[i:]
    return text.rstrip() + "\n" + line + "\n"

# memory_limit
text = set_or_add(text, "memory_limit", mem_limit)

# zend_extension — prefer existing opcache line, else add with full .so path
ze_pat = re.compile(r"(?m)^[; ]*zend_extension\s*=\s*.*opcache.*$")
ze_line = f"zend_extension = {so}" if so else "zend_extension = opcache"
if ze_pat.search(text):
    text = ze_pat.sub(ze_line, text, count=1)
else:
    text = "zend_extension = opcache\n" + text

# Ensure [opcache] section exists
if not re.search(r"(?m)^\[opcache\]\s*$", text):
    text = text.rstrip() + "\n\n[opcache]\n"

text = set_or_add(text, "opcache.enable", "1", "opcache")
text = set_or_add(text, "opcache.enable_cli", "0", "opcache")
text = set_or_add(text, "opcache.memory_consumption", opc_mem, "opcache")
text = set_or_add(text, "opcache.interned_strings_buffer", interned, "opcache")
text = set_or_add(text, "opcache.max_accelerated_files", opc_files, "opcache")
text = set_or_add(text, "opcache.validate_timestamps", "1", "opcache")
text = set_or_add(text, "opcache.revalidate_freq", reval, "opcache")
text = set_or_add(text, "opcache.save_comments", "1", "opcache")

# JIT only PHP 8+
mm = f"{ver[0]}.{ver[1]}" if len(ver) == 2 else ver
try:
    major = float(mm)
except ValueError:
    major = 0.0
if major >= 8.0:
    text = set_or_add(text, "opcache.jit", jit, "opcache")
    text = set_or_add(text, "opcache.jit_buffer_size", jit_buf, "opcache")

if text == orig:
    print(f"unchanged {path}")
elif dry:
    print(f"[dry-run] would patch {path}")
else:
    open(path, "w", encoding="utf-8").write(text)
    print(f"patched {path}")
PY
}

patch_fpm() {
  local conf="$1"
  [[ -f "$conf" ]] || return 0
  backup_once "$conf"
  python3 - "$conf" "$FPM_MAX_CHILDREN" "$FPM_START" "$FPM_MIN_SPARE" \
    "$FPM_MAX_SPARE" "$FPM_MAX_REQUESTS" "$DRY_RUN" <<'PY'
import re, sys
path, max_c, start, mn, mx, max_req, dry = sys.argv[1:]
dry = dry == "1"
text = open(path, encoding="utf-8", errors="ignore").read()
orig = text

def set_key(text, key, value):
    pat = re.compile(rf"(?m)^[; ]*{re.escape(key)}\s*=\s*.*$")
    line = f"{key} = {value}"
    if pat.search(text):
        return pat.sub(line, text, count=1)
    # insert after pm = dynamic if present
    m = re.search(r"(?m)^pm\s*=\s*.*$", text)
    if m:
        i = m.end()
        return text[:i] + "\n" + line + text[i:]
    return text.rstrip() + "\n" + line + "\n"

text = set_key(text, "pm.max_children", max_c)
text = set_key(text, "pm.start_servers", start)
text = set_key(text, "pm.min_spare_servers", mn)
text = set_key(text, "pm.max_spare_servers", mx)
text = set_key(text, "pm.max_requests", max_req)

if text == orig:
    print(f"unchanged {path}")
elif dry:
    print(f"[dry-run] would patch {path}")
else:
    open(path, "w", encoding="utf-8").write(text)
    print(f"patched {path}")
PY
}

restart_php_fpm() {
  local ver="$1"
  # aaPanel: prefer init.d reload/restart (systemd restart often races an already-running master)
  if [[ -x "/etc/init.d/php-fpm-${ver}" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[dry-run] /etc/init.d/php-fpm-${ver} reload || restart"
    else
      if /etc/init.d/php-fpm-${ver} reload 2>/dev/null; then
        echo "reloaded /etc/init.d/php-fpm-${ver}"
      else
        /etc/init.d/php-fpm-${ver} stop 2>/dev/null || true
        sleep 1
        # clear stale sock if master died uncleanly
        rm -f "/tmp/php-cgi-${ver}.sock" 2>/dev/null || true
        /etc/init.d/php-fpm-${ver} start || true
        echo "restarted /etc/init.d/php-fpm-${ver}"
      fi
    fi
    return 0
  fi
  local svc
  for svc in "php-fpm-${ver}" "php${ver}-fpm" "php-fpm${ver}"; do
    if systemctl list-unit-files "$svc.service" &>/dev/null; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[dry-run] systemctl reload-or-restart $svc"
      else
        systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc" || true
        echo "restarted $svc"
      fi
      return 0
    fi
  done
  # fallback: graceful reload via USR2
  local conf="/www/server/php/${ver}/etc/php-fpm.conf"
  if [[ -f "$conf" ]]; then
    local pid
    pid=$(pgrep -f "php-fpm: master process \\(${conf}\\)" || true)
    if [[ -n "${pid}" ]]; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[dry-run] kill -USR2 ${pid}"
      else
        kill -USR2 "${pid}" || true
        echo "signaled php-fpm master pid=${pid} for ${ver}"
      fi
    fi
  fi
}

patch_mysql() {
  local cnf=""
  for c in /etc/my.cnf /www/server/mysql/my.cnf /etc/mysql/my.cnf; do
    [[ -f "$c" ]] && cnf="$c" && break
  done
  [[ -n "$cnf" ]] || { echo "skip mysql: no my.cnf"; return 0; }
  backup_once "$cnf"
  python3 - "$cnf" "$INNODB_BUFFER" "$DRY_RUN" <<'PY'
import re, sys
path, buf, dry = sys.argv[1:]
dry = dry == "1"
text = open(path, encoding="utf-8", errors="ignore").read()
orig = text

def set_key(text, key, value):
    pat = re.compile(rf"(?mi)^[; #]*{re.escape(key)}\s*=\s*.*$")
    line = f"{key} = {value}"
    if pat.search(text):
        return pat.sub(line, text, count=1)
    if re.search(r"(?mi)^\[mysqld\]", text):
        return re.sub(r"(?mi)^(\[mysqld\].*)$", r"\1\n" + line, text, count=1)
    return text.rstrip() + f"\n[mysqld]\n{line}\n"

text = set_key(text, "innodb_buffer_pool_size", buf)
# Query cache is removed/useless on MySQL 8 / MariaDB modern; force off if keys exist
text = set_key(text, "query_cache_type", "0")
text = set_key(text, "query_cache_size", "0")

if text == orig:
    print(f"unchanged {path}")
elif dry:
    print(f"[dry-run] would patch {path}")
else:
    open(path, "w", encoding="utf-8").write(text)
    print(f"patched {path}")
PY
  if [[ "$DRY_RUN" -eq 0 ]]; then
    systemctl restart mysqld 2>/dev/null || systemctl restart mysql 2>/dev/null || systemctl restart mariadb 2>/dev/null || true
    echo "restarted mysql/mariadb (if present)"
  fi
}

patch_redis() {
  local cnf=""
  for c in /www/server/redis/redis.conf /etc/redis/redis.conf /etc/redis.conf; do
    [[ -f "$c" ]] && cnf="$c" && break
  done
  [[ -n "$cnf" ]] || { echo "skip redis: no conf"; return 0; }
  backup_once "$cnf"
  python3 - "$cnf" "$REDIS_MAXMEMORY" "$DRY_RUN" <<'PY'
import re, sys
path, mem, dry = sys.argv[1:]
dry = dry == "1"
text = open(path, encoding="utf-8", errors="ignore").read()
orig = text

def set_key(text, key, value):
    pat = re.compile(rf"(?m)^[; #]*{re.escape(key)}\s+.*$")
    line = f"{key} {value}"
    if pat.search(text):
        return pat.sub(line, text, count=1)
    return text.rstrip() + "\n" + line + "\n"

text = set_key(text, "maxmemory", mem)
text = set_key(text, "maxmemory-policy", "allkeys-lru")

if text == orig:
    print(f"unchanged {path}")
elif dry:
    print(f"[dry-run] would patch {path}")
else:
    open(path, "w", encoding="utf-8").write(text)
    print(f"patched {path}")
PY
  if [[ "$DRY_RUN" -eq 0 ]]; then
    systemctl restart redis 2>/dev/null || systemctl restart redis-server 2>/dev/null || true
    echo "restarted redis (if present)"
  fi
}

patch_nginx_http() {
  local conf="/www/server/nginx/conf/nginx.conf"
  [[ -f "$conf" ]] || { echo "skip nginx: no nginx.conf"; return 0; }
  backup_once "$conf"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] would ensure open_file_cache + bump fastcgi_buffers in $conf"
    return 0
  fi
  python3 - "$conf" <<'PY'
import re, sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="ignore")
orig = text

# Only inject open_file_cache — do NOT redeclare client_* / large_client_*
# (aaPanel proxy.conf already sets client_body_buffer_size).
if "open_file_cache" not in text:
    snippet = """
    # aaPanel perf (fix-aapanel)
    open_file_cache max=200000 inactive=20s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;
"""
    text, n = re.subn(r"(http\s*\{)", r"\1" + snippet, text, count=1)
    print(f"injected open_file_cache n={n}")
else:
    print("open_file_cache already present")

# Bump existing fastcgi buffer directives in-place (avoid duplicates)
def bump(text, key, value):
    pat = re.compile(rf"(?m)^(\s*){re.escape(key)}\s+[^;]+;")
    if pat.search(text):
        return pat.sub(rf"\1{key} {value};", text, count=1), True
    return text, False

text, a = bump(text, "fastcgi_buffers", "16 32k")
text, b = bump(text, "fastcgi_buffer_size", "64k")
if a or b:
    print("bumped fastcgi buffers in-place")

if text != orig:
    path.write_text(text, encoding="utf-8")
    print(f"patched {path}")
else:
    print(f"unchanged {path}")
PY
  nginx -t && nginx -s reload
}

echo "== optimize_php_perf =="
echo "memory_limit=$MEMORY_LIMIT opcache_mem=${OPCACHE_MEM}M files=$OPCACHE_FILES fpm_max=$FPM_MAX_CHILDREN"

shopt -s nullglob
vers=()
if [[ -n "$ONLY_VER" ]]; then
  vers=("$ONLY_VER")
else
  for d in /www/server/php/*/; do
    v=$(basename "$d")
    [[ "$v" =~ ^[0-9]+$ ]] || continue
    vers+=("$v")
  done
fi

for ver in "${vers[@]}"; do
  root="/www/server/php/$ver"
  [[ -d "$root" ]] || { echo "skip missing $root"; continue; }
  echo "---- PHP $ver ----"
  so=$(find "$root/lib/php/extensions" -name opcache.so 2>/dev/null | head -1 || true)
  if [[ -z "$so" ]]; then
    echo "WARN: opcache.so not found for PHP $ver — install OPcache in aaPanel first"
  fi
  for ini in "$root/etc/php.ini" "$root/etc/php-cli.ini" "$root/etc/php-fpm.ini"; do
    [[ -f "$ini" ]] && patch_php_ini "$ini" "$ver" "$so"
  done
  patch_fpm "$root/etc/php-fpm.conf"
  restart_php_fpm "$ver"

  # verify via CLI (loads php.ini or php-cli.ini)
  bin="$root/bin/php"
  if [[ -x "$bin" && "$DRY_RUN" -eq 0 ]]; then
    "$bin" -d detect_unicode=0 -r '
      echo "CLI memory_limit=".ini_get("memory_limit")."\n";
      echo "Zend OPcache loaded=".(extension_loaded("Zend OPcache")?"yes":"no")."\n";
      echo "opcache.enable=".ini_get("opcache.enable")."\n";
      echo "opcache.memory_consumption=".ini_get("opcache.memory_consumption")."\n";
      echo "opcache.max_accelerated_files=".ini_get("opcache.max_accelerated_files")."\n";
      echo "opcache.revalidate_freq=".ini_get("opcache.revalidate_freq")."\n";
      if (PHP_VERSION_ID >= 80000) {
        echo "opcache.jit=".ini_get("opcache.jit")."\n";
        echo "opcache.jit_buffer_size=".ini_get("opcache.jit_buffer_size")."\n";
      }
    ' 2>/dev/null || echo "verify skipped (CLI ini may differ from FPM)"
  fi
done

[[ "$WITH_MYSQL" -eq 1 ]] && patch_mysql
[[ "$WITH_REDIS" -eq 1 ]] && patch_redis
[[ "$WITH_NGINX" -eq 1 ]] && patch_nginx_http

echo "== done =="
echo "Next: hit a .php URL and confirm OPcache via phpinfo or a one-shot probe."
echo "App layer (manual): XenForo Redis/page cache; WP object/page cache; CF Full SSL."
