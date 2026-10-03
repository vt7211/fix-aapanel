# fix-aapanel

Cursor Agent Skill for diagnosing and fixing **aaPanel** (BT Panel) + **Virtual Host** production issues.

## Install

### As a personal Cursor skill

```bash
git clone <your-repo-url> ~/.cursor/skills/fix-aapanel
# or copy this folder to ~/.cursor/skills/fix-aapanel
```

### On a target aaPanel server (scripts)

From this repo root:

```bash
bash -n scripts/sync_vhost_ssl.sh
bash scripts/patch_acme_hybrid.sh   # after copying to the server
# follow references/hardening.md for cron install
```

## What it covers

- Panel unreachable (Cloudflare proxy, domain bind, ports)
- Virtual Host UI SSL on port **57001** + sync after panel renew
- Site Let's Encrypt auto-renew failures (hybrid ACME, metadata repair)
- Node.js project SSL (`bind_extranet` / nginx map)
- Post-migrate PHP slowness (OPcache/JIT, FPM, InnoDB, Redis, nginx) for XenForo, WordPress, and all PHP versions
- Preventative crons and ops hygiene

## Layout

```
fix-aapanel/
├── SKILL.md
├── README.md
├── references/
│   ├── access.md
│   ├── ssl-renew.md
│   ├── nodejs.md
│   ├── php-perf.md
│   └── hardening.md
└── scripts/
    ├── sync_vhost_ssl.sh
    ├── vhost_ssl_maintain.py
    ├── patch_acme_hybrid.sh
    └── optimize_php_perf.sh
```

## Safety

- Do not commit real panel passwords, admin paths, or private keys.
- Do not publish customer domain incident notes with secrets.
- Test `nginx -t` before reload on production.

## License

Use freely for your own infrastructure. No warranty.
