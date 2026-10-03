#!/bin/bash
# Sync aaPanel SSL cert to vhost_virtual (port 57001)
# Only copies + restarts when panel cert differs from vhost cert.

set -euo pipefail

PANEL_CERT="/www/server/panel/ssl/certificate.pem"
PANEL_KEY="/www/server/panel/ssl/privateKey.pem"
VHOST_CERT="/www/server/vhost_virtual/data/cert/vhost.crt"
VHOST_KEY="/www/server/vhost_virtual/data/cert/vhost.key"
LOG_FILE="/www/server/panel/logs/sync_vhost_ssl.log"
TMP_DIR="/tmp/sync_vhost_ssl.$$"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$TMP_DIR"

if [[ ! -f "$PANEL_CERT" || ! -f "$PANEL_KEY" ]]; then
  log "ERROR: Panel SSL files missing"
  exit 1
fi

if [[ ! -d "$(dirname "$VHOST_CERT")" ]]; then
  log "ERROR: vhost_virtual cert directory missing"
  exit 1
fi

# Validate panel cert/key pair
if ! openssl x509 -noout -in "$PANEL_CERT" >/dev/null 2>&1; then
  log "ERROR: Panel certificate is invalid"
  exit 1
fi

PANEL_MOD=$(openssl x509 -noout -modulus -in "$PANEL_CERT" 2>/dev/null | openssl md5)
KEY_MOD=$(openssl rsa -noout -modulus -in "$PANEL_KEY" 2>/dev/null | openssl md5)
if [[ "$PANEL_MOD" != "$KEY_MOD" ]]; then
  log "ERROR: Panel certificate and private key do not match"
  exit 1
fi

PANEL_FP=$(openssl x509 -noout -fingerprint -sha256 -in "$PANEL_CERT" 2>/dev/null | cut -d= -f2)
VHOST_FP=""
if [[ -f "$VHOST_CERT" ]]; then
  VHOST_FP=$(openssl x509 -noout -fingerprint -sha256 -in "$VHOST_CERT" 2>/dev/null | cut -d= -f2 || true)
fi

if [[ -n "$VHOST_FP" && "$PANEL_FP" == "$VHOST_FP" ]]; then
  log "OK: Certificates already in sync (fingerprint match), skip"
  exit 0
fi

log "INFO: Syncing panel SSL -> vhost_virtual"
log "INFO: Panel FP=$PANEL_FP"
log "INFO: Vhost FP=${VHOST_FP:-missing}"

# Backup current vhost certs
if [[ -f "$VHOST_CERT" ]]; then
  cp -a "$VHOST_CERT" "${VHOST_CERT}.bak.$(date +%Y%m%d%H%M%S)"
fi
if [[ -f "$VHOST_KEY" ]]; then
  cp -a "$VHOST_KEY" "${VHOST_KEY}.bak.$(date +%Y%m%d%H%M%S)"
fi

# Stage then install (atomic-ish)
cp "$PANEL_CERT" "$TMP_DIR/vhost.crt"
cp "$PANEL_KEY" "$TMP_DIR/vhost.key"
chown www:www "$TMP_DIR/vhost.crt" "$TMP_DIR/vhost.key"
chmod 600 "$TMP_DIR/vhost.crt" "$TMP_DIR/vhost.key"

cp -a "$TMP_DIR/vhost.crt" "$VHOST_CERT"
cp -a "$TMP_DIR/vhost.key" "$VHOST_KEY"

# Keep SSL enabled in vhost config
if [[ -f /www/server/vhost_virtual/config/template/ssl.yaml.tpl ]]; then
  # Preserve current https port if default.yaml exists
  HTTPS_PORT="57001"
  if [[ -f /www/server/vhost_virtual/config/server_port.pl ]]; then
    HTTPS_PORT=$(tr -d '[:space:]' </www/server/vhost_virtual/config/server_port.pl)
  fi
  # Only rewrite yaml server block paths if needed; ensure httpsAddr kept
  if ! grep -q 'httpsCertPath: "./data/cert/vhost.crt"' /www/server/vhost_virtual/manifest/config/default.yaml 2>/dev/null; then
    sed "s/{{#HTTPS_SERVER_PORT}}/${HTTPS_PORT}/g; s/{{#HTTP_SERVER_PORT}}//g" \
      /www/server/vhost_virtual/config/template/ssl.yaml.tpl \
      > /www/server/vhost_virtual/manifest/config/default.yaml
    # Force empty address and correct httpsAddr (template may leave placeholders)
    sed -i "s/^  address:.*/  address: \"\"/; s/^  httpsAddr:.*/  httpsAddr: \":${HTTPS_PORT}\"/" \
      /www/server/vhost_virtual/manifest/config/default.yaml
  fi
fi

rm -f /www/server/vhost_virtual/config/close_ssl.pl
echo "False" >/www/server/vhost_virtual/config/not_auto_ssl.pl

systemctl restart vhost_virtual.service
sleep 2

if ! systemctl is-active --quiet vhost_virtual.service; then
  log "ERROR: vhost_virtual failed to start after cert sync"
  exit 1
fi

NEW_FP=$(openssl x509 -noout -fingerprint -sha256 -in "$VHOST_CERT" 2>/dev/null | cut -d= -f2)
EXPIRE=$(openssl x509 -noout -enddate -in "$VHOST_CERT" 2>/dev/null | cut -d= -f2)
log "SUCCESS: Synced. FP=$NEW_FP expire=$EXPIRE"
exit 0
