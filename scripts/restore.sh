#!/usr/bin/env bash
# LookPress restore: put a lookpress-backup-*.tar.gz (made by scripts/backup.sh) back
# into a docker-compose or bare/Plesk deployment. Safe by default:
#   - verifies the archive (manifest.json + SHA256SUMS) before touching anything
#   - prints exactly what will be overwritten, then requires --yes (or interactive y/N)
#   - keeps the current DB / uploads next to the originals as *.pre-restore-<ts>
#   - stops the app for the DB swap, starts it again (also on failure)
# Never prints DSN passwords.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: scripts/restore.sh <lookpress-backup-YYYYmmdd-HHMMSS.tar.gz> [options]

  --yes                Do not ask for confirmation (required when there is no TTY).
  --mode auto|docker|local
                       Force the environment (default: auto — docker if a container
                       named "lookpress" exists, else local).
  --container NAME     Docker container name (default: lookpress)
  --root DIR           App root for local mode (default: parent of this script)
  --env-file FILE      Env file to read DB_DSN from (default: <root>/.look.env)
  --dsn DSN            Override the target DSN (e.g. restore into a scratch DB/file).
  --uploads-dir DIR    Override the target uploads directory (local mode).
  --service NAME       Local mode: systemd unit to stop/start (auto-detected when root).
  --no-stop            Do not stop/start anything (scratch restores, or you stop it yourself).
  --db-only | --uploads-only
                       Restore only one part.
  --dry-run            Verify + show the plan, change nothing.
  -h, --help           This help.
EOF
}

log()  { printf '[restore] %s\n' "$*" >&2; }
warn() { printf '[restore] WARNING: %s\n' "$*" >&2; }
die()  { printf '[restore] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
# docker wrapper: on Git Bash / MSYS, stop the shell from rewriting container-side paths
# (/data/cms.db -> C:...); host paths handed to "docker cp" go through hostpath().
docker() { MSYS_NO_PATHCONV=1 command docker "$@"; }
hostpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf "%s" "$1"; fi; }

ARCHIVE=""; YES=0; MODE="auto"; CONTAINER="lookpress"; ENV_FILE=""; DSN_OVERRIDE=""
UPLOADS_DIR=""; SERVICE=""; NO_STOP=0; DO_DB=1; DO_UPLOADS=1; DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)      YES=1; shift ;;
    --mode)        MODE="${2:?}"; shift 2 ;;
    --container)   CONTAINER="${2:?}"; shift 2 ;;
    --root)        ROOT_DIR="$(cd "${2:?}" && pwd)"; shift 2 ;;
    --env-file)    ENV_FILE="${2:?}"; shift 2 ;;
    --dsn)         DSN_OVERRIDE="${2:?}"; shift 2 ;;
    --uploads-dir) UPLOADS_DIR="${2:?}"; shift 2 ;;
    --service)     SERVICE="${2:?}"; shift 2 ;;
    --no-stop)     NO_STOP=1; shift ;;
    --db-only)     DO_UPLOADS=0; shift ;;
    --uploads-only) DO_DB=0; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) [ -z "$ARCHIVE" ] || die "only one archive allowed"; ARCHIVE="$1"; shift ;;
  esac
done
[ -n "$ARCHIVE" ] || { usage >&2; exit 2; }
[ -f "$ARCHIVE" ] || die "archive not found: $ARCHIVE"
case "$MODE" in auto|docker|local) ;; *) die "--mode must be auto, docker or local" ;; esac
[ "$DO_DB" = 1 ] || [ "$DO_UPLOADS" = 1 ] || die "--db-only and --uploads-only exclude each other"
[ -n "$ENV_FILE" ] || ENV_FILE="$ROOT_DIR/.look.env"
have tar || die "tar not found"

# ---------------------------------------------------------------- unpack + verify
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lookpress-restore.XXXXXX")"
STOPPED_APP=""
stop_app() {
  if [ "$MODE" = docker ]; then docker stop "$CONTAINER" >/dev/null; STOPPED_APP="docker:$CONTAINER"
  else systemctl stop "$SERVICE"; STOPPED_APP="systemd:$SERVICE"; fi
}
start_app() {
  case "$STOPPED_APP" in
    docker:*)  docker start "$CONTAINER" >/dev/null ;;
    systemd:*) systemctl start "$SERVICE" ;;
  esac
  STOPPED_APP=""
}
cleanup() {
  if [ -n "$STOPPED_APP" ]; then warn "restarting app after failure: $STOPPED_APP"; start_app || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

log "verifying archive: $ARCHIVE"
tar -xzf "$ARCHIVE" -C "$WORK"
[ -f "$WORK/manifest.json" ] || die "not a LookPress backup: manifest.json missing"
manifest_get() { sed -n "s/^[[:space:]]*\"$1\":[[:space:]]*\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}$/\1/p" "$WORK/manifest.json" | head -n1; }
M_ENGINE="$(manifest_get engine)"
M_DBFILE="$(manifest_get db_file)"
M_CREATED="$(manifest_get created_at)"
M_COMMIT="$(manifest_get app_commit)"
M_CONSISTENT="$(manifest_get consistent)"
[ -n "$M_ENGINE" ] && [ -n "$M_DBFILE" ] || die "manifest.json is incomplete"
[ -f "$WORK/$M_DBFILE" ] || die "manifest names '$M_DBFILE' but it is not in the archive"
[ -f "$WORK/uploads.tar.gz" ] || die "uploads.tar.gz missing from archive"
if [ -f "$WORK/SHA256SUMS" ]; then
  if have sha256sum; then (cd "$WORK" && sha256sum -c --quiet SHA256SUMS) || die "checksum mismatch — archive is corrupt"
  elif have shasum;    then (cd "$WORK" && shasum -a 256 -c --quiet SHA256SUMS) || die "checksum mismatch — archive is corrupt"
  else warn "no sha256sum/shasum: skipping checksum verification"; fi
  log "checksums OK"
else
  warn "archive has no SHA256SUMS (older backup); skipping checksum verification"
fi
tar -tzf "$WORK/uploads.tar.gz" >/dev/null || die "uploads.tar.gz is not a valid tar.gz"
[ "$M_CONSISTENT" != "false" ] || warn "manifest says this backup was a LIVE copy (consistent=false)"

# ---------------------------------------------------------------- environment + DSN
docker_container_exists() { have docker && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx -- "$CONTAINER"; }
docker_container_running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx -- "$CONTAINER"; }
env_file_get() {
  [ -f "$1" ] || return 1
  local line; line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?$2=" "$1" | tail -n1 || true)"
  [ -n "$line" ] || return 1
  line="${line#*=}"; line="${line%$'\r'}"
  case "$line" in \"*\") line="${line#\"}"; line="${line%\"}" ;; \'*\') line="${line#\'}"; line="${line%\'}" ;; esac
  printf '%s' "$line"
}
if [ "$MODE" = auto ]; then if docker_container_exists; then MODE=docker; else MODE=local; fi; fi

DSN=""
if [ -n "$DSN_OVERRIDE" ]; then
  DSN="$DSN_OVERRIDE"
elif [ "$MODE" = docker ]; then
  docker_container_exists || die "container '$CONTAINER' not found"
  DSN="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER" 2>/dev/null | grep -E '^DB_DSN=' | tail -n1 | cut -d= -f2- || true)"
  [ -n "$DSN" ] || DSN="sqlite:///data/cms.db"
else
  if [ -n "${DB_DSN:-}" ]; then DSN="$DB_DSN"
  elif DSN="$(env_file_get "$ENV_FILE" DB_DSN)"; then :
  else die "no DB_DSN: set it, put it in '$ENV_FILE', or pass --dsn"; fi
fi
[ -n "$UPLOADS_DIR" ] || { [ "$MODE" = docker ] || UPLOADS_DIR="$ROOT_DIR/uploads"; }

DSN_SCHEME="${DSN%%://*}"; DSN_REST="${DSN#*://}"
DSN_USER=""; DSN_PASS=""; DSN_HOST=""; DSN_PORT=""; DSN_DB=""
case "$DSN_SCHEME" in
  sqlite|sqlite3) ENGINE=sqlite; DSN_DB="${DSN_REST%%\?*}" ;;
  mysql|mariadb) ENGINE=mysql ;;
  postgres|postgresql|pgsql) ENGINE=postgres ;;
  *) die "unsupported DSN scheme '$DSN_SCHEME'" ;;
esac
if [ "$ENGINE" != sqlite ]; then
  rest="${DSN_REST%%\?*}"
  if [ "${rest#*@}" != "$rest" ]; then auth="${rest%@*}"; rest="${rest#*@}"; DSN_USER="${auth%%:*}"; [ "$auth" = "$DSN_USER" ] || DSN_PASS="${auth#*:}"; fi
  DSN_DB="${rest#*/}"; [ "$DSN_DB" != "$rest" ] || DSN_DB=""
  hostport="${rest%%/*}"; DSN_HOST="${hostport%%:*}"; [ "$hostport" = "$DSN_HOST" ] || DSN_PORT="${hostport#*:}"
  [ -n "$DSN_HOST" ] || DSN_HOST=127.0.0.1
  [ -n "$DSN_DB" ] || die "DSN has no database name"
  unset rest auth hostport
fi
[ "$ENGINE" = "$M_ENGINE" ] || die "backup engine is '$M_ENGINE' but the target DSN is '$ENGINE' — use --dsn or a matching backup"
if [ "$ENGINE" = sqlite ] && [ "$MODE" = local ]; then case "$DSN_DB" in /*) ;; *) DSN_DB="$ROOT_DIR/$DSN_DB" ;; esac; fi

# how will we stop the app?
STOP_HOW="none (--no-stop)"
if [ "$NO_STOP" != 1 ]; then
  if [ "$MODE" = docker ]; then
    STOP_HOW="docker stop/start $CONTAINER"
  elif have systemctl; then
    if [ -z "$SERVICE" ] && [ "$(id -u)" = 0 ]; then
      SERVICE="$(systemctl list-units --type=service --state=active --no-legend --plain 'look-*' 2>/dev/null | awk '{print $1}' || true)"
      [ "$(printf '%s\n' "$SERVICE" | grep -c .)" -le 1 ] || die "several look-* services active; pick one with --service"
    fi
    if [ -n "$SERVICE" ]; then STOP_HOW="systemctl stop/start $SERVICE"
    else STOP_HOW="NONE DETECTED — stop the LOOK service yourself first (or run as root / pass --service)"; fi
  else
    STOP_HOW="NONE DETECTED — stop the app yourself first"
  fi
fi

# ---------------------------------------------------------------- plan
TS="$(date +%Y%m%d-%H%M%S)"
cat >&2 <<EOF

================ RESTORE PLAN ================
archive     : $ARCHIVE
created     : ${M_CREATED:-?}   app commit: ${M_COMMIT:-?}   engine: $M_ENGINE
target mode : $MODE
stop/start  : $STOP_HOW
EOF
if [ "$DO_DB" = 1 ]; then
  case "$ENGINE" in
    sqlite)   printf 'database    : OVERWRITE sqlite file %s\n              (current kept as %s.pre-restore-%s)\n' "$DSN_DB" "$DSN_DB" "$TS" >&2 ;;
    mysql)    printf 'database    : REPLACE tables in mysql db "%s" on %s:%s as "%s" (DROP TABLE IF EXISTS + reload)\n' "$DSN_DB" "$DSN_HOST" "${DSN_PORT:-3306}" "$DSN_USER" >&2 ;;
    postgres) printf 'database    : REPLACE objects in postgres db "%s" on %s:%s as "%s" (DROP IF EXISTS + reload)\n' "$DSN_DB" "$DSN_HOST" "${DSN_PORT:-5432}" "$DSN_USER" >&2 ;;
  esac
fi
if [ "$DO_UPLOADS" = 1 ]; then
  if [ "$MODE" = docker ]; then printf 'uploads     : REPLACE %s:/app/uploads (current kept as /app/uploads.pre-restore-%s)\n' "$CONTAINER" "$TS" >&2
  else printf 'uploads     : REPLACE %s (current kept as %s.pre-restore-%s)\n' "$UPLOADS_DIR" "$UPLOADS_DIR" "$TS" >&2; fi
fi
printf '==============================================\n\n' >&2

if [ "$DRY_RUN" = 1 ]; then log "dry-run: nothing changed"; exit 0; fi
if [ "$YES" != 1 ]; then
  if [ -t 0 ]; then
    printf 'Proceed with the restore? [y/N] ' >&2
    read -r ans
    case "$ans" in y|Y|yes|YES) ;; *) die "aborted" ;; esac
  else
    die "refusing to restore without --yes (no TTY for confirmation)"
  fi
fi
if [ "$DO_DB" = 1 ] && [ "$NO_STOP" != 1 ] && [ "$MODE" = local ] && [ -z "$SERVICE" ]; then
  warn "no service will be stopped; restoring the DB under a running app is unsafe unless you stopped it yourself"
fi

# ---------------------------------------------------------------- uploads (docker: while running, so we can exec)
restore_uploads_docker() {
  log "uploads: swapping /app/uploads in container"
  if docker_container_running; then
    docker exec "$CONTAINER" sh -c "if [ -d /app/uploads ]; then mv /app/uploads '/app/uploads.pre-restore-$TS'; fi; mkdir -p /app/uploads"
  else
    warn "container not running: old uploads are NOT set aside, new files are overlaid"
  fi
  mkdir -p "$WORK/u" && tar -xzf "$WORK/uploads.tar.gz" -C "$WORK/u"
  docker cp "$(hostpath "$WORK/u/uploads")/." "$CONTAINER:/app/uploads/"
}
restore_uploads_local() {
  log "uploads: $UPLOADS_DIR"
  if [ -d "$UPLOADS_DIR" ]; then mv "$UPLOADS_DIR" "$UPLOADS_DIR.pre-restore-$TS"; fi
  mkdir -p "$(dirname "$UPLOADS_DIR")"
  mkdir -p "$WORK/u" && tar -xzf "$WORK/uploads.tar.gz" -C "$WORK/u"
  mv "$WORK/u/uploads" "$UPLOADS_DIR"
  if [ -d "$UPLOADS_DIR.pre-restore-$TS" ]; then
    # keep the owner of the previous directory (Plesk: the panel user)
    owner="$(stat -c '%u:%g' "$UPLOADS_DIR.pre-restore-$TS" 2>/dev/null || true)"
    [ -z "$owner" ] || chown -R "$owner" "$UPLOADS_DIR" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------- database
restore_sqlite_docker() {
  log "sqlite: replacing $DSN_DB in container"
  docker cp "$CONTAINER:$DSN_DB" "$(hostpath "$WORK/current.db")" 2>/dev/null && docker cp "$(hostpath "$WORK/current.db")" "$CONTAINER:$DSN_DB.pre-restore-$TS" || true
  docker cp "$(hostpath "$WORK/$M_DBFILE")" "$CONTAINER:$DSN_DB"
  if [ -f "$WORK/db.sqlite-wal" ]; then docker cp "$(hostpath "$WORK/db.sqlite-wal")" "$CONTAINER:$DSN_DB-wal"
  else
    # stale WAL/SHM from the old DB must not be applied to the restored file; drop them
    # (container is stopped, so we do it via a throw-away helper on the same volumes)
    docker run --rm --volumes-from "$CONTAINER" --entrypoint sh "$(docker inspect --format '{{.Config.Image}}' "$CONTAINER")" \
      -c "rm -f '$DSN_DB-wal' '$DSN_DB-shm'" 2>/dev/null || warn "could not remove stale -wal/-shm (check /data manually)"
  fi
}
restore_sqlite_local() {
  log "sqlite: replacing $DSN_DB"
  mkdir -p "$(dirname "$DSN_DB")"
  [ ! -f "$DSN_DB" ] || cp -p "$DSN_DB" "$DSN_DB.pre-restore-$TS"
  owner=""; [ ! -f "$DSN_DB" ] || owner="$(stat -c '%u:%g' "$DSN_DB" 2>/dev/null || true)"
  cp "$WORK/$M_DBFILE" "$DSN_DB.tmp-restore" && mv -f "$DSN_DB.tmp-restore" "$DSN_DB"
  rm -f "$DSN_DB-wal" "$DSN_DB-shm"
  [ ! -f "$WORK/db.sqlite-wal" ] || cp "$WORK/db.sqlite-wal" "$DSN_DB-wal"
  [ -z "$owner" ] || chown "$owner" "$DSN_DB" 2>/dev/null || true
}
restore_mysql() {
  local cnf="$WORK/my.cnf" port=()
  ( umask 077; { printf '[client]\nhost=%s\nuser=%s\n' "$DSN_HOST" "$DSN_USER"
                 [ -z "$DSN_PORT" ] || printf 'port=%s\n' "$DSN_PORT"
                 [ -z "$DSN_PASS" ] || printf 'password=%s\n' "$DSN_PASS"; } > "$cnf" )
  [ -z "$DSN_PORT" ] || port=(-P "$DSN_PORT")
  if have mysql; then
    log "mysql: loading $M_DBFILE into '$DSN_DB' (host client)"
    mysql --defaults-extra-file="$cnf" "$DSN_DB" < "$WORK/$M_DBFILE"
  elif have docker && docker ps --format '{{.Names}}' | grep -qx -- "$DSN_HOST"; then
    log "mysql: loading $M_DBFILE inside container '$DSN_HOST'"
    docker exec -i -e MYSQL_PWD="$DSN_PASS" "$DSN_HOST" mysql -h 127.0.0.1 "${port[@]}" -u "$DSN_USER" "$DSN_DB" < "$WORK/$M_DBFILE"
  else die "mysql client not found"; fi
}
restore_postgres() {
  local port=(); [ -z "$DSN_PORT" ] || port=(-p "$DSN_PORT")
  if have psql; then
    log "postgres: loading $M_DBFILE into '$DSN_DB' (host client)"
    PGPASSWORD="$DSN_PASS" psql -v ON_ERROR_STOP=1 -q -h "$DSN_HOST" "${port[@]}" -U "$DSN_USER" -d "$DSN_DB" -f "$WORK/$M_DBFILE" >/dev/null
  elif have docker && docker ps --format '{{.Names}}' | grep -qx -- "$DSN_HOST"; then
    log "postgres: loading $M_DBFILE inside container '$DSN_HOST'"
    docker exec -i -e PGPASSWORD="$DSN_PASS" "$DSN_HOST" psql -v ON_ERROR_STOP=1 -q -h 127.0.0.1 "${port[@]}" -U "$DSN_USER" -d "$DSN_DB" < "$WORK/$M_DBFILE" >/dev/null
  else die "psql not found"; fi
}

# ---------------------------------------------------------------- execute
if [ "$DO_UPLOADS" = 1 ] && [ "$MODE" = docker ]; then restore_uploads_docker; fi

if [ "$DO_DB" = 1 ]; then
  if [ "$NO_STOP" != 1 ] && { [ "$MODE" = docker ] || [ -n "$SERVICE" ]; }; then
    log "stopping app ($STOP_HOW)"; stop_app
  fi
  case "$ENGINE" in
    sqlite)   if [ "$MODE" = docker ]; then restore_sqlite_docker; else restore_sqlite_local; fi ;;
    mysql)    restore_mysql ;;
    postgres) restore_postgres ;;
  esac
fi

if [ "$DO_UPLOADS" = 1 ] && [ "$MODE" = local ]; then restore_uploads_local; fi

if [ -n "$STOPPED_APP" ]; then log "starting app"; start_app; fi
if [ "$MODE" = docker ] && docker_container_running; then
  # docker cp creates files as root; the app runs as user "look" (see Dockerfile)
  docker exec -u root "$CONTAINER" sh -c 'chown -R look:look /data /app/uploads 2>/dev/null || true' || true
fi

# ---------------------------------------------------------------- post-restore hint
URL=""
if [ "$MODE" = docker ]; then
  URL="http://localhost:$(docker port "$CONTAINER" 7400/tcp 2>/dev/null | head -n1 | sed 's/.*://' || true)"
  [ "$URL" != "http://localhost:" ] || URL="http://localhost:8080"
else
  URL="$(env_file_get "$ENV_FILE" APP_URL || true)"; [ -n "$URL" ] || URL="http://127.0.0.1:9100"
fi
cat >&2 <<EOF

[restore] done.
  Check:   curl -sS -o /dev/null -w '%{http_code}\n' "$URL/"      (expect 200)
           curl -sS -o /dev/null -w '%{http_code}\n' "$URL/admin"  (expect 200/302)
  Rollback: the previous DB/uploads are kept as *.pre-restore-$TS — delete them
            once you are happy, or move them back to undo.
EOF
