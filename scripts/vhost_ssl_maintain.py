#!/www/server/panel/pyenv/bin/python3
"""Keep Virtual Host Let's Encrypt certs renewable.

aaPanel vhost_virtual auto-renew has two recurring bugs:
1. A successful renew can store issuer as the intermediate CN (YR1/YR2)
   and endtime as a small integer, so the next cycle treats the cert as
   expired and then refuses it ("issuer is not Let's Encrypt").
2. A failed attempt writes a "24 hours only renew once" log, and later
   skip logs refresh that window, so renew never retries.

This job treats the deployed certificate file as source of truth, repairs
panel metadata, and re-issues via HTTP-01 webroot if a cert is within
20 days of expiry.
"""
import os
import shutil
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone

os.chdir("/www/server/panel")
sys.path.insert(0, "/www/server/panel")
sys.path.insert(0, "/www/server/panel/class")

NGINX_VHOST = "/www/server/vhost_virtual/vhost/nginx"
SSL_DB = "/www/server/vhost_virtual/data/db/ssl.sqlite"
WEB_DB = "/www/server/vhost_virtual/data/db/website.sqlite"
WEBROOT = "/www/wwwroot/acme_webroot"
RENEW_WITHIN_SECONDS = 20 * 86400
LOG = "/www/server/panel/logs/vhost_ssl_maintain.log"


def log(msg):
    line = "[{}] {}".format(datetime.now().strftime("%Y-%m-%d %H:%M:%S"), msg)
    print(line, flush=True)
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    with open(LOG, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")


def cert_end(path):
    out = subprocess.check_output(
        ["openssl", "x509", "-in", path, "-noout", "-enddate", "-issuer"],
        text=True,
    )
    end = None
    issuer = ""
    for line in out.splitlines():
        if line.startswith("notAfter="):
            end = datetime.strptime(line.split("=", 1)[1], "%b %d %H:%M:%S %Y %Z").replace(
                tzinfo=timezone.utc
            )
        elif line.startswith("issuer="):
            issuer = line.split("=", 1)[1]
    if end is None:
        raise RuntimeError("cannot parse {}".format(path))
    return int(end.timestamp()), end.strftime("%Y-%m-%d"), issuer


def domains_for(web, site_id, fallback):
    rows = web.execute(
        "SELECT domain FROM domains WHERE site_id=? ORDER BY domain_id", (site_id,)
    ).fetchall()
    names = [row[0] for row in rows if row[0]]
    return names or [fallback]


def install_cert(site_name, fullchain, key):
    dest = os.path.join(NGINX_VHOST, site_name)
    cert_path = os.path.join(dest, "certificate.pem")
    key_path = os.path.join(dest, "private_key.pem")
    stamp = time.strftime("%Y%m%d%H%M%S")
    if os.path.exists(cert_path):
        shutil.copy2(cert_path, cert_path + ".bak." + stamp)
    if os.path.exists(key_path):
        shutil.copy2(key_path, key_path + ".bak." + stamp)
    with open(cert_path, "w", encoding="utf-8") as fh:
        fh.write(fullchain)
    with open(key_path, "w", encoding="utf-8") as fh:
        fh.write(key)
    os.chmod(cert_path, 0o644)
    os.chmod(key_path, 0o600)


def issue(domains):
    from acme_v2 import acme_v2

    client = acme_v2()
    res = client.apply_cert(domains, "http", WEBROOT)
    if not res.get("status"):
        raise RuntimeError(res.get("msg") or "apply failed")
    fullchain = res["cert"] + res.get("root", "")
    return fullchain, res["private_key"]


def main():
    ssl = sqlite3.connect(SSL_DB)
    web = sqlite3.connect(WEB_DB)
    sites = web.execute(
        "SELECT site_id, site_name, cert_id FROM sites WHERE cert_id > 0"
    ).fetchall()
    renewed = False
    now = int(time.time())

    for site_id, site_name, cert_id in sites:
        cert_path = os.path.join(NGINX_VHOST, site_name, "certificate.pem")
        key_path = os.path.join(NGINX_VHOST, site_name, "private_key.pem")
        if not os.path.exists(cert_path):
            continue
        end_ts, end_day, issuer = cert_end(cert_path)
        is_le = "Let's Encrypt" in issuer or "YR" in issuer
        if not is_le:
            log("skip {}: not a Let's Encrypt cert".format(site_name))
            continue

        if end_ts - now <= RENEW_WITHIN_SECONDS:
            names = domains_for(web, site_id, site_name)
            log("renew {} {}".format(site_name, ",".join(names)))
            try:
                fullchain, key = issue(names)
                install_cert(site_name, fullchain, key)
                end_ts, end_day, issuer = cert_end(cert_path)
                renewed = True
                log("renewed {} until {}".format(site_name, end_day))
            except Exception as exc:
                log("renew failed {}: {}".format(site_name, exc))

        row = ssl.execute(
            "SELECT issuer, endtime, certificate FROM letsencrypts WHERE cert_id=?", (cert_id,)
        ).fetchone()
        if row is None:
            continue
        db_issuer, db_end, db_pem = row
        pem = open(cert_path, encoding="utf-8").read()
        key = open(key_path, encoding="utf-8").read() if os.path.exists(key_path) else ""
        stored_mismatch = (db_pem or "").strip() != pem.strip()
        if db_issuer != "Let's Encrypt" or int(db_end or 0) != end_ts or stored_mismatch:
            ssl.execute(
                "UPDATE letsencrypts SET issuer=?, not_after=?, status=1, endtime=?, "
                "certificate=?, private_key=?, error_info='' WHERE cert_id=?",
                ("Let's Encrypt", end_day, end_ts, pem, key, cert_id),
            )
            web.execute(
                "UPDATE sites SET ssl_expire=? WHERE site_id=?", (end_ts, site_id)
            )
            log("repaired metadata {} issuer={} end={}".format(site_name, db_issuer, db_end))

    ssl.commit()
    web.commit()
    if renewed:
        subprocess.check_call(["nginx", "-t"])
        subprocess.check_call(["nginx", "-s", "reload"])
        log("nginx reloaded")
    else:
        log("no renew needed")


if __name__ == "__main__":
    main()
