# Panel access & Virtual Host login

## Recover panel URL

```bash
bt default          # or: bt 14
cat /www/server/panel/data/port.pl
cat /www/server/panel/data/admin_path.pl
cat /www/server/panel/data/domain.conf 2>/dev/null
```

URL shape: `https://<host>:<port><admin_path>`  
Example shape only: `https://panel.example.com:14805/xxxxxxxx`

## Common blockers

### 1. Cloudflare orange-cloud proxy

Custom panel ports (e.g. `14805`, `57001`) are **not** supported through Cloudflare HTTP proxy. DNS must be **DNS only** (grey cloud) to the VPS A record.

```bash
dig +short DOMAIN A @1.1.1.1
curl -skI --connect-timeout 10 "https://DOMAIN:PORT/ADMIN_PATH"
```

### 2. Domain-only bind

If `domain.conf` is set, Host by raw IP fails. Options:

- Use the bound domain, or
- Unbind: `bt 12` (confirm with operator first)

### 3. Firewall / security group

Release panel port + `80`/`443` (and `57001` if using Virtual Host UI).

### 4. Main panel UI spins / hangs

Often unrelated to SSL. Check:

```bash
systemctl status btpanel nginx
tail -50 /www/server/panel/logs/error.log
df -h /                    # disk full breaks panel badly
```

## Port 57001 (Sub aaPanel / Virtual Host UI)

Service: `vhost_virtual`  
Cert files: `/www/server/vhost_virtual/data/cert/vhost.crt` + `vhost.key`  
Login path: `https://DOMAIN:57001/account/login`  
`one_key_login` tokens expire — create a fresh link from main panel → Virtual Host.

### Symptom: `NET::ERR_CERT_AUTHORITY_INVALID` + HSTS

Cause: self-signed aapanel cert on 57001 while main panel has Let's Encrypt.

**Fix:** sync panel LE cert → vhost cert, restart service:

```bash
# Prefer installing scripts/sync_vhost_ssl.sh then:
bash /www/server/panel/script/sync_vhost_ssl.sh
```

Manual equivalent: copy `/www/server/panel/ssl/certificate.pem` → `vhost.crt` and `privateKey.pem` → `vhost.key`, verify modulus match, `systemctl restart vhost_virtual`.

After previous bad cert, Chrome HSTS may still block: `chrome://net-internals/#hsts` → delete domain.

### Keep 57001 SSL current

Panel renew (cron `acme_v2.py --renew_v3`) does **not** update 57001. Install daily sync after panel renew:

```cron
10 6 * * * /www/server/cron/sync_vhost_ssl >> /www/server/cron/sync_vhost_ssl.log 2>&1
```

See [hardening.md](hardening.md).
