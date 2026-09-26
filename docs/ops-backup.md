# LookPress operations: backup and restore

One command in, one archive out; one command back. Two scripts, no external
dependencies beyond `bash` (4.4+), `tar`, `gzip`, `date`, plus the database client
when the site runs on MySQL/PostgreSQL:

| Script | Purpose |
|---|---|
| `scripts/backup.sh` | Snapshot the database and `uploads/` into `lookpress-backup-YYYYmmdd-HHMMSS.tar.gz` |
| `scripts/restore.sh` | Verify an archive and put it back, with a confirmation gate and automatic rollback copies |
| `scripts/backup.ps1` | Windows wrapper: finds Git Bash and runs `backup.sh` |

Both scripts detect where LookPress runs:

* **docker** — a container named `lookpress` exists (`docker ps -a`). The DB is
  `/data/cms.db` on volume `lp_data`, uploads are `/app/uploads` on `lp_uploads`
  (see `docker-compose.yml`). The DSN is read from the container's `DB_DSN`.
* **local / Plesk** — otherwise. `DB_DSN` comes from the environment or from
  `<root>/.look.env` (the file is parsed, never sourced); uploads are `<root>/uploads`.
  This matches the layout in `docs/plesk-deploy.md` (`data/` + `uploads/` in the docroot).

Force it with `--mode docker|local`; point at another checkout with `--root DIR`.
Nothing is printed that contains a password: DSN credentials go to the DB clients
through a `0600` defaults file (MySQL) or the process environment (Postgres).

## What is in a backup

```
lookpress-backup-20260926-202430.tar.gz
├── manifest.json     created_at, mode, engine, db_file, db_method, consistent, app_commit, hostname
├── db.sqlite         SQLite snapshot            (engine sqlite)
│   db.mysql.sql      mysqldump, --add-drop-table (engine mysql)
│   db.pgsql.sql      pg_dump --clean --if-exists (engine postgres)
├── uploads.tar.gz    the uploads directory, top-level entry "uploads/"
└── SHA256SUMS        checksums of the members above (verified on restore)
```

**Included:** every table LookPress owns (pages, posts, versions, orders, media
metadata, sessions, settings, schema-migration markers) and every uploaded file.

**Not included** — keep these in your configuration management:
`.look.env` / `.env` (secrets: `ADMIN_PASSWORD`, `DB_DSN`, `APP_URL`), the
application source (it is in git; `manifest.json` records the commit so you can
check out the matching code), `logs/`, `.look_cache/` bytecode caches, TLS
certificates, the web-server/systemd/Plesk configuration, and the MySQL/Postgres
*server* users and grants (the dump contains schema + data of one database only).

## Running a backup

```bash
# default: <root>/backups/, keep everything
scripts/backup.sh

# production style: a dedicated directory, keep the newest 14 archives
scripts/backup.sh --out /var/backups/lookpress --keep 14

# docker host with SQLite, no downtime (see caveat below)
scripts/backup.sh --out /var/backups/lookpress --keep 14 --sidecar

# see what would happen (detection + DSN parse), write nothing
scripts/backup.sh --dry-run
```

The last line on stdout is the archive path, so it can be piped into an off-site
copy: `f=$(scripts/backup.sh --out /var/backups/lookpress --keep 14) && rclone copy "$f" remote:lookpress/`.
Diagnostics go to stderr, prefixed `[backup]`.

`--keep N` deletes only files in `--out` that match `lookpress-backup-<digits>-<digits>.tar.gz`,
never anything else, and only after the new archive was written successfully.

Add `backups/` to `.gitignore` if you keep the default output directory inside the checkout.

### Schedules

Plesk → *Websites & Domains → Scheduled Tasks* (run as the subscription's system
user, daily at 03:15, "Run a command"):

```
/bin/bash /var/www/vhosts/<parent>/<domain>/scripts/backup.sh --out /var/www/vhosts/<parent>/<domain>/private/backups --keep 14
```

`private/` is outside the docroot on Plesk, so archives are never web-served.
The panel user can read `data/cms.db` and `uploads/` (the service runs as that
user, see `plesk-deploy.md`), so no root is needed. Note that on a bare/Plesk host
an online SQLite snapshot needs `sqlite3` **or** `python3` on the host (both are
normally present on AlmaLinux/Ubuntu); otherwise see the consistency caveat.

Docker host — root's crontab (`crontab -e`), nightly with retention and an
off-site copy:

```
15 3 * * * cd /srv/lookpress && ./scripts/backup.sh --out /var/backups/lookpress --keep 14 --sidecar >> /var/log/lookpress-backup.log 2>&1
```

Windows (Docker Desktop) — Task Scheduler action:
`powershell.exe -File C:\lookpress\scripts\backup.ps1 --out D:\backups\lookpress --keep 14 --sidecar`.

### Retention

Nightly with `--keep 14` gives two weeks of daily points. For longer history run a
second job into another directory (`--out /var/backups/lookpress-monthly --keep 12`
on the 1st of the month). The scripts do not do off-site transfer; add `rclone`,
`restic`, `scp`, or the Plesk Backup Manager (include the backup directory) after
the command — a backup that lives only on the server it protects is not a backup.

## SQLite: online snapshot vs. stop-copy

Copying a live SQLite file (`cp`, `docker cp`) while the app is writing can produce
a torn database, and LookPress runs SQLite in WAL mode (`cms.db-wal`/`-shm` next to
the file), so a plain copy may also miss committed data. `backup.sh` therefore
tries, in order:

1. `sqlite3 cms.db ".backup ..."` — SQLite's online backup API (consistent, no downtime)
2. `python3` with its built-in `sqlite3` module calling the same backup API
3. Docker only, `--sidecar [IMAGE]`: a throw-away container (`python:3-alpine` by
   default) started with `--volumes-from lookpress` runs step 2 against the volume
   and streams the snapshot out. No downtime, nothing installed in the app image.
4. **Stop / copy / start.** The app is stopped (`docker stop`, or `systemctl stop
   look-<domain>` when running as root, or `--service NAME`), the file plus any
   `-wal` is copied, the app is started again — also on failure, via a trap.
   Downtime is a second or two. The script says so on stderr when it does this.
   Pass `--no-stop` to fail instead of stopping.
5. Last resort, local mode only, when nothing above is possible: copy the live
   file and mark `"consistent": false` in the manifest with a warning.

**The stock `codlook/look:1.0.0` image contains neither `sqlite3` nor `python3`
(nor `tar`)**, so under docker compose the choice is `--sidecar` (recommended for
cron) or the stop-copy fallback. Uploads are always taken with `docker cp` from
the running container; a file being uploaded at that exact moment may be partial,
which is harmless (the next backup has it).

## MySQL and PostgreSQL

The DSN `scheme://user:pass@host:port/db?query` is parsed by the script. Commands used:

| Engine | Backup | Restore |
|---|---|---|
| mysql / mariadb | `mysqldump --defaults-extra-file=<0600 file> --single-transaction --quick --routines --triggers --events --add-drop-table DB` | `mysql --defaults-extra-file=<0600 file> DB < db.mysql.sql` |
| postgres | `PGPASSWORD=… pg_dump -h -p -U --no-owner --no-privileges --clean --if-exists --format=plain DB` | `PGPASSWORD=… psql -v ON_ERROR_STOP=1 -h -p -U -d DB -f db.pgsql.sql` |

If the client is not installed on the host but the DSN host is the name of a
running container (compose service), the same command is executed with
`docker exec` inside that container, credentials passed via `MYSQL_PWD`/`PGPASSWORD`.
`--single-transaction` gives a consistent InnoDB snapshot without locking; the
site stays up during the dump. Restores replace the tables inside the existing
database (`DROP TABLE IF EXISTS` / `DROP … IF EXISTS`); the database itself and
the user must already exist. A DSN password containing `@`, `:` or `/` must be
URL-encoded in `DB_DSN` for LookPress anyway; the scripts do not decode it, so use
a password without those characters or an alphanumeric one for the backup user.

## Restore drill

Practise this before you need it. Every step is what `restore.sh` prints in its plan.

1. Pick the archive and look inside without changing anything:
   ```bash
   scripts/restore.sh /var/backups/lookpress/lookpress-backup-20260926-202430.tar.gz --dry-run
   ```
   This verifies the tarball, `manifest.json`, `SHA256SUMS`, checks that the
   backup engine matches the target DSN, and prints the plan: which file/database
   will be overwritten, where the current copy will be kept, and how the app will
   be stopped.
2. Make sure the code matches: `git log -1 <app_commit from manifest>`; if the
   archive is older than the current schema, restoring is still fine — the
   entrypoint / `lk setup.lk migrate` + `lk setup_v2.lk` run the idempotent
   migrations on the next start (docker) or when you run them (Plesk, see
   `plesk-deploy.md`).
3. Run it:
   ```bash
   scripts/restore.sh /var/backups/lookpress/lookpress-backup-20260926-202430.tar.gz --yes
   ```
   Without `--yes` you get a `y/N` prompt on a terminal; with no terminal and no
   `--yes` the script refuses. What happens, in order:
   * docker: `uploads/` in the container is renamed to `uploads.pre-restore-<ts>`
     and the archived one is copied in; then `docker stop lookpress`.
     local: `systemctl stop look-<domain>` if it can be detected (root) or was
     given with `--service`; otherwise the plan says `NONE DETECTED` and you must
     stop the service yourself first (Plesk: *Extensions → LOOK → domain → Stop*,
     or `systemctl stop look-<domain-dashed>` as root).
   * SQLite: the current `cms.db` is copied to `cms.db.pre-restore-<ts>`, the
     archived file replaces it, stale `-wal`/`-shm` are removed.
     MySQL/Postgres: the dump is loaded (see table above).
   * local: `uploads/` is renamed to `uploads.pre-restore-<ts>` and replaced,
     keeping the previous owner (the Plesk panel user).
   * The app is started again. In docker, `chown look:look /data /app/uploads`
     runs inside the container because `docker cp` writes files as root while
     the app runs as user `look`.
4. Check, as the script suggests:
   ```bash
   curl -sS -o /dev/null -w '%{http_code}\n' https://<domain>/        # 200
   curl -sS -o /dev/null -w '%{http_code}\n' https://<domain>/admin   # 200 or 302
   ```
   Open a restored page and one uploaded image in the browser.
5. Clean up when satisfied: delete `*.pre-restore-<ts>` (docker:
   `docker exec lookpress sh -c 'rm -rf /app/uploads.pre-restore-* /data/cms.db.pre-restore-*'`).
   To undo the restore instead, stop the app and move them back.

Partial restores: `--db-only` or `--uploads-only`. Skipping the stop/start:
`--no-stop` (you are responsible for the app not writing meanwhile).

## Testing a restore on a scratch copy (without touching production)

The archive is self-contained, so you can rehearse anywhere:

```bash
# 1. a scratch checkout of the same commit
git clone <repo> /tmp/lp-scratch && cd /tmp/lp-scratch && git checkout <app_commit>

# 2. restore INTO the scratch paths only — --dsn/--uploads-dir override the target,
#    --no-stop leaves every service alone, --mode local ignores the docker container
scripts/restore.sh /var/backups/lookpress/lookpress-backup-…tar.gz \
  --mode local --root /tmp/lp-scratch \
  --dsn sqlite:///tmp/lp-scratch/data/cms.db --uploads-dir /tmp/lp-scratch/uploads --no-stop --yes

# 3. run it on a spare port and look at it
cd /tmp/lp-scratch && DB_DSN=sqlite:///tmp/lp-scratch/data/cms.db ADMIN_PASSWORD=test \
  lk-fcgi --mode http --port 7411 --workers 1 app.lk &
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:7411/
```

With docker: `container_name: lookpress` is fixed in `docker-compose.yml`, so a
second stack on the same host needs a copy of the compose file with a different
`container_name` (e.g. `lookpress-scratch`), different `ports`, and its own project
name (`docker compose -p lp-scratch -f compose.scratch.yml up -d` gives it separate
`lp-scratch_lp_data` / `lp-scratch_lp_uploads` volumes). Then
`scripts/restore.sh <archive> --container lookpress-scratch --yes` touches only that stack.
For MySQL/Postgres, point `--dsn` at an empty scratch database and user you created
for the drill.

`--dry-run` is always safe and is the fastest way to confirm an archive is intact
(`checksums OK`) — run it on a sample of your archives periodically.

## Troubleshooting

* `container 'lookpress' not found` — the compose stack is down or has another
  name: `--container NAME`, or `--mode local` for a bare install.
* `no DB_DSN` — local mode needs `DB_DSN` in the environment or `<root>/.look.env`;
  `--env-file` / `--root` if they live elsewhere.
* `backup engine is 'sqlite' but the target DSN is 'mysql'` — you cannot restore a
  SQLite backup into MySQL with this tool; export/import through the app instead.
* `checksum mismatch` — the archive was truncated or altered in transit; use another copy.
* `several look-* services active` — one host serves several LOOK sites: `--service look-<domain-dashed>`.
* `refusing to restore without --yes` — cron/CI context; add `--yes` deliberately.
* Windows / Git Bash: the scripts convert host paths and disable MSYS path
  rewriting for docker themselves; run `scripts/backup.ps1` or `bash scripts/backup.sh`.
