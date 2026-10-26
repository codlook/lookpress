# Deploying LookPress on Plesk (LOOK Language extension)

This is how LookPress is deployed to a Plesk server that has the **LOOK Language**
extension installed (it ships the `lk` / `lk-fcgi` runtime under `/opt/look`, so
you do **not** install LOOK separately). Everything below is done from the Plesk
panel and as the domain's own system user — no root shell and no hand-written
systemd files. Reference deployment: `test.codlook.com`.

Requires the LOOK Language extension **1.2.0 or newer** (LOOK 1.0.32+): it runs
the service as the domain's user and loads an env file.

## How the LOOK extension serves a domain

The extension does **not** serve `.lk` files like PHP. Per domain it creates a
**systemd service** that runs the LOOK server as a front controller, and points
the domain's web server at it:

```
systemd:  look-<domain-dashed>.service
          User = <the domain's system user>   (owner of the document root)
          ExecStart = /opt/look/lk-fcgi --mode http --port 9100 --workers 4 --script <docroot>/app.lk
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

### 1. Upload the files

From the repo, produce a clean snapshot (tracked files only):

```bash
git archive --format=tar.gz -o lookpress.tar.gz HEAD
```

Upload it to the domain's document root with the Plesk **File Manager** (it can
extract archives) or over SFTP as the domain's user. Create the `data/` and
`uploads/` folders — they hold the SQLite database and uploaded files and are
kept across redeploys. Files uploaded this way are owned by the domain's user,
which is what the service runs as.

### 2. Create `.look.env`

In the document root, create `.look.env` (File Manager → New file; set its
permissions to `600`). Use one database DSN:

```ini
# SQLite (default; the file lives in data/)
DB_DSN=sqlite:///var/www/vhosts/<parent>/<domain>/data/cms.db
# MySQL 8 — the database and user created in Plesk → Databases
# DB_DSN=mysql://<db-user>:<db-password>@localhost:3306/<db-name>
# PostgreSQL 16
# DB_DSN=postgres://<db-user>:<db-password>@localhost:5432/<db-name>

# Used ONCE: the setup creates the first admin (username `admin`) with it when no user exists.
# Login always checks the database; this value does not change an existing admin's password.
# After the first setup, change the password in /admin/users and delete this line.
ADMIN_PASSWORD=<strong-random>
# Required: signs the CSRF cookie (at least 32 characters; LookPress does not start without it).
# Generate with `openssl rand -hex 32`. Changing it: put the old value in LOOK_SECRET_PREVIOUS for a
# while, so forms that are already open keep working.
LOOK_SECRET=<openssl rand -hex 32>
# Cookies are Secure (the site is behind TLS)
LOOK_SESSION_SECURE=1
# Honour X-Forwarded-Proto from the local proxy
LOOK_TRUSTED_PROXY=127.0.0.1
APP_URL=https://<domain>
```

The format is `KEY=VALUE`, one per line. A line that **starts** with `#` is a
comment. **There are no comments at the end of a line**: in
`LOOK_SESSION_SECURE=1   # cookies Secure` the value is `1   # cookies Secure`,
not `1` — put the comment on its own line above. (The service log warns when a
value contains ` #`.) Quotes around a value are removed. A password that
contains `#` is fine as long as no space comes before the `#`.

### 3. Add the domain in the panel

**Extensions → LOOK Language → Applications → Add**:

| Field | Value |
|---|---|
| Domain | `<domain>` |
| Script | `/var/www/vhosts/<parent>/<domain>/app.lk` |
| Env file | `/var/www/vhosts/<parent>/<domain>/.look.env` |
| Mode | HTTP |
| Port | the one the panel suggests (e.g. `9100`) |

The panel starts the service. Until the database is migrated (next step) the
pages answer with errors; that is expected.

### 4. Migrate the database

Open an SSH session as the domain's user and run, in the document root, the same
idempotent steps as `docker/entrypoint.sh`. `/opt/look/look-env` is the
extension's env-file loader — it reads `.look.env` exactly as the service does:

```bash
cd /var/www/vhosts/<parent>/<domain>
bash /opt/look/look-env .look.env /opt/look/lk setup.lk migrate
# demo content, first install only:
LOOKPRESS_SEED=1 bash /opt/look/look-env .look.env /opt/look/lk setup.lk seed
LOOKPRESS_SEED=1 LOOKPRESS_PRESET=kurumsal bash /opt/look/look-env .look.env /opt/look/lk setup_v2.lk
```

Without demo content, run `bash /opt/look/look-env .look.env /opt/look/lk setup_v2.lk`
instead of the last two lines.

The user's shell must be able to see `/opt/look`: in Plesk → Websites & Domains →
**SSH Access**, choose `/bin/bash`. The chrooted shell (`/bin/bash (chrooted)`) does
not contain `/opt/look`, so `lk` is not found there.

Then press **Restart** on the domain in the panel.

### 5. Verify

`https://<domain>/` returns `200`, and the panel's **Logs** for the domain show
`Listening on port 9100` and `VM dispatch ready — <n> route`, with no
`VM setup error` line.

### Updating

Upload the new snapshot over the old files (keep `data/`, `uploads/` and
`.look.env`), run step 4's `migrate` and `setup_v2.lk` lines again (they are
idempotent), and press **Restart**.

## Troubleshooting: "I can't delete a file/folder in the site"

**Symptom.** A folder (e.g. `logs/`) or file in the site's docroot cannot be
deleted from the Plesk File Manager or over FTP — "permission denied" — even
though it is your own site.

**Why.** File Manager and FTP act as the subscription's **system user** (e.g.
`codlook.com_qq1ybm2crrp`). Extension versions before 1.2.0 ran the LOOK service
as **root** (their generated unit had no `User=`), so every file the app created
— its log directory, its SQLite DB, uploads — is owned by `root:root`. On
`test.codlook.com` the leftover was:

```
docroot        owner = codlook.com_qq1ybm2crrp : psaserv  (drwxr-x---)
docroot/logs   owner = root : root                        (drwxr-xr-x)  <-- 755, root
docroot/logs/look-2026-09-24.log  owner = root : root
```

To delete a directory you need write+execute on it; the `logs/` directory is
mode `755` owned by `root`, so **only root can create/delete entries inside it**.

**Fix.** Update the extension to 1.2.0+ and press **Restart** on the domain: the
service is rewritten to run as the domain's user, and the restart output says how
many files in the docroot are still owned by root. A server administrator gives
them back once:

```bash
chown -R <panel-user>:psacln /var/www/vhosts/<parent>/<domain>/logs
```

**Rule of thumb:** on Plesk, an app runs as the domain's system user. A service
running as root inside a subscription docroot produces files the site owner can
never manage.
