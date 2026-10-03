---
name: fix-aapanel
description: >-
  Diagnose and fix aaPanel (BT Panel) production issues: panel unreachable,
  Cloudflare/domain bind, Virtual Host port 57001 SSL, Let's Encrypt auto-renew,
  ACME HTTP-01 404/502, Node.js site SSL bind_extranet, and SSL metadata repair.
  Use when the user mentions aaPanel, aapanel, BT Panel, vhost_virtual, port
  14805/57001/60880, acme-challenge, SSL renew failures, panel login spinning,
  NET::ERR_CERT_AUTHORITY_INVALID, or Vietnamese requests about panel/SSL/hosting.
---

# fix-aapanel

Playbook for aaPanel + Virtual Host (`vhost_virtual`) ops. Prefer **diagnose → patch → verify**. Do not print passwords, private keys, or panel security paths in chat.

## Quick triage

| Symptom | Start here |
|---|---|
| Panel URL không mở / timeout | [references/access.md](references/access.md) |
| Port 57001 SSL invalid / HSTS | [references/access.md](references/access.md) §57001 |
| Site SSL expired / renew fail / `24 hours only renew once` | [references/ssl-renew.md](references/ssl-renew.md) |
| Node site LE 403 / no nginx vhost | [references/nodejs.md](references/nodejs.md) |
| Install preventative cron / sync | [references/hardening.md](references/hardening.md) |

## Hard rules (learned the hard way)

1. **Three SSL systems — do not mix**
   - Virtual Host **site** certs → `/www/server/vhost_virtual/vhost/nginx/<domain>/`
   - Classic panel sites → `/www/server/panel/vhost/cert` + cron `acme_v2.py --renew_v3`
   - Panel UI cert → `/www/server/panel/ssl` (sync **only** to port 57001 via `sync_vhost_ssl.sh`)

2. **Never remove `:60880` from ACME alone.** Port 60880 is intentionally down except during native renew (token in memory). Replacing `proxy_pass` with webroot-only broke renew (July → September outage). Use the **hybrid** block in [references/ssl-renew.md](references/ssl-renew.md).

3. **Source of truth = deployed `certificate.pem`**, not SQLite PEM. After renew, repair `letsencrypts.issuer` / `endtime` or the next cycle fails forever (`issuer is not Let's Encrypt`, tiny `endtime`).

4. **`24 hours only renew once` is a local lock**, not Let's Encrypt rate limit. Skip rows refresh the window. Fix nginx + metadata, then issue via panel `acme_v2` webroot — do not mass-delete `renew_logs` as the fix.

5. **Do not `apt install certbot`** on broken-apt hosts. Use `/www/server/panel/pyenv/bin/python3` + `acme_v2.apply_cert(..., "http", "/www/wwwroot/acme_webroot")`.

6. **Never leak secrets.** Use `bt 14` / `bt default` on the server for credentials. Unbind domain with `bt 12` only if needed.

## First commands on any new host

```bash
bt default                    # URL, port, admin path (do not paste password to chat)
systemctl is-active nginx vhost_virtual
crontab -l | rg -i 'acme|ssl|vhost|sync'
ss -tlnp | rg '14805|57001|80|443|60880'
```

## Install reusable scripts (this skill)

Copy from skill `scripts/` onto the target server:

| Script | Install path | Cron |
|---|---|---|
| `scripts/sync_vhost_ssl.sh` | `/www/server/panel/script/sync_vhost_ssl.sh` | `10 6 * * *` (after panel renew ~05:xx) |
| `scripts/vhost_ssl_maintain.py` | `/www/server/panel/script/vhost_ssl_maintain.py` | `20 4 * * *` — repair metadata + renew if ≤20 days |
| `scripts/patch_acme_hybrid.sh` | run once / after site rebuild | restores hybrid ACME on all VH sites |

Wrappers + log paths: see [references/hardening.md](references/hardening.md).

## Done checklist

- [ ] Live `openssl s_client` expiry matches disk cert (apex + `www`)
- [ ] Hybrid ACME present in **both** `vhost.conf` and `ssl_verify.conf`
- [ ] `letsencrypts.issuer` = `Let's Encrypt`, `endtime` = real unix `notAfter`
- [ ] Maintain + sync crons present; logs show recent healthy runs
- [ ] No challenge tokens or private keys left in `/tmp` or webroot

## Related local skill

On hosts that already have `aapanel-ssl-renew`, prefer that skill for SSL-only deep work. This skill is the **full** install-to-ops playbook for GitHub reuse.
