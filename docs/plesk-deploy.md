# Deploying LookPress on Plesk (LOOK Language extension)

This is how LookPress is deployed to a Plesk server that already has the **LOOK
Language** extension installed (it ships the `lk` / `lk-fcgi` runtime under
`/opt/look`, so you do **not** install LOOK separately). Reference deployment:
`test.codlook.com`.

## How the LOOK extension serves a domain

The extension does **not** serve `.lk` files like PHP. Instead, per enabled
domain it creates a **systemd service** that runs the LOOK FastCGI server as a
front controller, and points the domain's web server at it:

```
systemd:  look-<domain-dashed>.service
          ExecStart = /opt/look/lk-fcgi --mode http --port 9100 --workers 4 app.lk
          WorkingDirectory = <docroot>
Apache:   vhost.conf / vhost_ssl.conf
          ProxyPass /.well-known !
          ProxyPass / http://127.0.0.1:9100/
nginx:    proxies to Apache (Plesk default)
```

So **every** request for the domain is proxied to `lk-fcgi`, which runs
`app.lk` — exactly LookPress's front-controller model. There is no per-file
execution and no static serving of source files.

## Deploy procedure

From the repo, produce a clean snapshot (tracked files only) and lay it in the
docroot:

```bash
git archive --format=tar -o lookpress.tar HEAD
# upload lookpress.tar to the server, then on the server:
D=/var/www/vhosts/<parent>/<domain>
U=<subscription-system-user>      # e.g. codlook.com_qq1ybm2crrp
G=psacln

systemctl stop look-<domain-dashed> || true
rm -f "$D/index.lk"               # remove the extension's sample app
tar -xf lookpress.tar -C "$D"
mkdir -p "$D/data" "$D/uploads"   # persistent, survive redeploys
chown -R "$U:$G" "$D"             # see "Run as the panel user" below
```

Configuration goes in an `EnvironmentFile` (mode `600`, owned by the panel
user), not inline in the unit:

```ini
# $D/.look.env
DB_DSN=sqlite:///<docroot>/data/cms.db
ADMIN_PASSWORD=<strong-random>     # unset => admin login disabled (fail-loud)
LOOK_SESSION_SECURE=1              # cookies Secure (site is behind TLS)
LOOK_TRUSTED_PROXY=127.0.0.1       # honour X-Forwarded-Proto from the proxy
APP_URL=https://<domain>
```

Point the service at `app.lk`, load the env file, and — importantly — run it as
the **panel user** (drop-in override, so it survives the extension rewriting the
main unit):

```ini
# /etc/systemd/system/look-<domain-dashed>.service.d/override.conf
[Service]
User=<panel-user>
Group=psacln
EnvironmentFile=<docroot>/.look.env
ExecStart=
ExecStart=/opt/look/lk-fcgi --mode http --port 9100 --workers 4 app.lk
```

Run the idempotent migrations once (as the panel user, so the DB is user-owned),
mirroring `docker/entrypoint.sh`, then start:

```bash
sudo -u "$U" bash -c "cd '$D' && DB_DSN=... /opt/look/lk setup.lk migrate"
sudo -u "$U" bash -c "cd '$D' && DB_DSN=... LOOKPRESS_SEED=1 /opt/look/lk setup.lk seed"
sudo -u "$U" bash -c "cd '$D' && DB_DSN=... ADMIN_PASSWORD=... LOOKPRESS_SEED=1 /opt/look/lk setup_v2.lk"
systemctl daemon-reload && systemctl start look-<domain-dashed>
```

Verify: `curl -s localhost:9100/` and `curl -sk https://<domain>/` should both
return `200`; the journal should show `VM modu aktif` and `48 route`.

## Troubleshooting: "I can't delete a file/folder in the site"

**Symptom.** A folder (e.g. `logs/`) or file in the site's docroot cannot be
deleted from the Plesk File Manager or over FTP — "permission denied" — even
though it is your own site.

**Why.** File Manager and FTP act as the subscription's **system user** (e.g.
`codlook.com_qq1ybm2crrp`). If a LOOK service ran as **root** (the extension's
generated unit has no `User=`, so it defaults to root), every file the app
created — its log directory, its SQLite DB, uploads — is owned by `root:root`.
On `test.codlook.com` the leftover was:

```
docroot        owner = codlook.com_qq1ybm2crrp : psaserv  (drwxr-x---)
docroot/logs   owner = root : root                        (drwxr-xr-x)  <-- 755, root
docroot/logs/look-2026-09-24.log  owner = root : root
```

To delete a directory you need write+execute on it; the `logs/` directory is
mode `755` owned by `root`, so **only root can create/delete entries inside it**.
The panel user cannot unlink the root-owned log file, so `rm -rf logs` fails, and
the folder can't be removed from the panel. This is a leftover from an earlier
LOOK app that ran as root.

**Fix (as root).**

```bash
rm -rf /var/www/vhosts/<parent>/<domain>/logs
```

**Prevention — run the service as the panel user, not root.** Add `User=` /
`Group=` to the service drop-in (see the override above) and `chown -R
<panel-user>:psacln` the docroot. Then the app writes the DB, sessions and
uploads as the panel user, and everything stays manageable from the panel — no
root-owned files accumulate. This is why LookPress's deploy sets `User=` and puts
the DB under a user-owned `data/` directory.

**Rule of thumb:** on Plesk, an app should run as the domain's system user. A
service running as root inside a subscription docroot is a footgun — it produces
files the site owner can never manage.
