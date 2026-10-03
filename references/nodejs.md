# Node.js projects on aaPanel

## Form fields (Website → Node project)

| Field | Value |
|---|---|
| Project path | Real app folder, e.g. `/www/wwwroot/sec1.vn` — **not** bare `/www/wwwroot` |
| Run opt | e.g. `npm start` / `node app.js` |
| Port | App listen port (e.g. `3001`), must match code |

Without `package.json` / a listening process, expect **502** after SSL works.

## SSL Apply fails with 403 on ACME

Classic cause: Node project created but **extranet / domain not bound to nginx**.

Check panel DB (`bind_extranet` / similar flag) or missing:

`/www/server/panel/vhost/nginx/node_<name>.conf`

### Fix

Via panel API / model (example pattern used successfully):

```bash
cd /www/server/panel && /www/server/panel/pyenv/bin/python3 - << 'PY'
import public
from projectModel.nodejsModel import main as nodejs
# Adjust site name
print(nodejs().bind_extranet(public.to_dict_obj({"project_name": "sec1"})))
PY
```

Or UI: enable map domain / bind extranet for the project, confirm nginx conf exists, reload nginx.

### Verify challenge

```bash
curl -sI "http://DOMAIN/.well-known/acme-challenge/" 
# or place a test file under the site's ACME path panel uses
```

Then re-apply Let's Encrypt (File Verification) in the panel.

## Notes

- Virtual Host **sub-accounts** use a different stack (`vhost_virtual`); Node sites under main panel are classic nginx vhosts — do not edit VH ACME blocks to “fix” Node SSL.
- Disk near-full (`df -h`) causes mysterious Node and SSL failures — free space first.
