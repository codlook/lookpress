#!/usr/bin/env bash
# LookPress one-command backup: database + uploads -> lookpress-backup-YYYYmmdd-HHMMSS.tar.gz
#
# Environments (auto-detected, or forced with --mode):
#   docker : a container named "lookpress" exists (docker compose dev/prod).
#            DB lives at /data/cms.db (volume lp_data), uploads at /app/uploads (lp_uploads).
#   local  : bare / Plesk deploy. DB_DSN comes from <root>/.look.env or the environment;
#            SQLite path from the DSN, uploads at <root>/uploads.
#
# Archive layout (see docs/ops-backup.md):
#   manifest.json        timestamp, engine, mode, app commit, consistency flag
#   db.sqlite | db.mysql.sql | db.pgsql.sql
#   uploads.tar.gz       the uploads directory (top-level dir "uploads/")
#   SHA256SUMS           checksums of the above (when sha256sum is available)
#
# Secrets: DSN passwords are never printed and never passed on a command line.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFIX="lookpress-backup-"

usage() {
  cat <<'EOF'
Usage: scripts/backup.sh [options]

  --out DIR            Where to write the archive (default: <root>/backups)
  --keep N             After a successful backup, delete older lookpress-backup-*.tar.gz
                       in --out, keeping the newest N (only files matching the pattern).
  --mode auto|docker|local
                       Force the environment (default: auto).
  --container NAME     Docker container name (default: lookpress)
  --root DIR           App root for local mode (default: parent of this script)
  --env-file FILE      Env file to read DB_DSN from (default: <root>/.look.env)
  --uploads-dir DIR    Override the uploads directory (local mode)
  --sidecar [IMAGE]    Docker + SQLite: take an ONLINE snapshot through a throw-away
                       sidecar container that mounts the app's volumes
                       (default image: python:3-alpine). Avoids stopping the app.
  --no-stop            Never stop the app. If an online SQLite snapshot is impossible,
                       fail instead of stop/copy/start.
  --service NAME       Local mode: systemd unit to stop/start for the copy fallback
                       (auto-detected from look-*.service when running as root).
  --dry-run            Show what would be done, do not create anything.
  -h, --help           This help.

Exit code 0 on success. The path of the archive is printed last.
EOF
}

log()  { printf '[backup] %s\n' "$*" >&2; }
warn() { printf '[backup] WARNING: %s\n' "$*" >&2; }
die()  { printf '[backup] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
# docker wrapper: on Git Bash / MSYS, stop the shell from rewriting container-side paths
# (/data/cms.db -> C:...); host paths handed to "docker cp" go through hostpath().
docker() { MSYS_NO_PATHCONV=1 command docker "$@"; }
hostpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf "%s" "$1"; fi; }

OUT_DIR=""
KEEP=""
MODE="auto"
CONTAINER="lookpress"
ENV_FILE=""
UPLOADS_DIR=""
SIDECAR=""
NO_STOP=0
SERVICE=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --out)        OUT_DIR="${2:?--out needs a value}"; shift 2 ;;
    --keep)       KEEP="${2:?--keep needs a value}"; shift 2 ;;
    --mode)       MODE="${2:?--mode needs a value}"; shift 2 ;;
    --container)  CONTAINER="${2:?--container needs a value}"; shift 2 ;;
    --root)       ROOT_DIR="$(cd "${2:?--root needs a value}" && pwd)"; shift 2 ;;
    --env-file)   ENV_FILE="${2:?--env-file needs a value}"; shift 2 ;;
    --uploads-dir) UPLOADS_DIR="${2:?--uploads-dir needs a value}"; shift 2 ;;
    --sidecar)
      if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then SIDECAR="$2"; shift 2; else SIDECAR="python:3-alpine"; shift; fi ;;
    --no-stop)    NO_STOP=1; shift ;;
    --service)    SERVICE="${2:?--service needs a value}"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

case "$MODE" in auto|docker|local) ;; *) die "--mode must be auto, docker or local" ;; esac
if [ -n "$KEEP" ] && ! [[ "$KEEP" =~ ^[0-9]+$ ]]; then die "--keep must be a non-negative integer"; fi
[ -n "$OUT_DIR" ] || OUT_DIR="$ROOT_DIR/backups"
[ -n "$ENV_FILE" ] || ENV_FILE="$ROOT_DIR/.look.env"

# ---------------------------------------------------------------- environment detection
docker_container_exists() {
  have docker || return 1
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx -- "$CONTAINER"
}
docker_container_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx -- "$CONTAINER"
}

# Read a single KEY=value line from an env file without sourcing it (no code execution).
env_file_get() { # file key
  [ -f "$1" ] || return 1
  local line
  line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?$2=" "$1" | tail -n1 || true)"
  [ -n "$line" ] || return 1
  line="${line#*=}"
  line="${line%$'\r'}"
  # strip one layer of surrounding quotes
  case "$line" in
    \"*\") line="${line#\"}"; line="${line%\"}" ;;
    \'*\') line="${line#\'}"; line="${line%\'}" ;;
  esac
  printf '%s' "$line"
}

if [ "$MODE" = "auto" ]; then
  if docker_container_exists; then MODE="docker"; else MODE="local"; fi
fi

DSN=""
if [ "$MODE" = "docker" ]; then
  docker_container_exists || die "container '$CONTAINER' not found (docker ps -a). Use --container or --mode local."
  # DSN as seen by the container (falls back to the image default).
  DSN="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER" 2>/dev/null \
        | grep -E '^DB_DSN=' | tail -n1 | cut -d= -f2- || true)"
  [ -n "$DSN" ] || DSN="sqlite:///data/cms.db"
else
  if [ -n "${DB_DSN:-}" ]; then
    DSN="$DB_DSN"
  elif DSN="$(env_file_get "$ENV_FILE" DB_DSN)"; then
    :
  else
    die "no DB_DSN: set it in the environment or in '$ENV_FILE' (see docs/plesk-deploy.md)"
  fi
  [ -n "$UPLOADS_DIR" ] || UPLOADS_DIR="$ROOT_DIR/uploads"
fi

# ---------------------------------------------------------------- DSN parsing (no secrets printed)
# scheme://[user[:pass]@][host[:port]]/dbname[?query]   or   sqlite://<path>
DSN_SCHEME="${DSN%%://*}"
DSN_REST="${DSN#*://}"
DSN_USER=""; DSN_PASS=""; DSN_HOST=""; DSN_PORT=""; DSN_DB=""
case "$DSN_SCHEME" in
  sqlite|sqlite3)
    ENGINE="sqlite"
    DSN_DB="${DSN_REST%%\?*}"
    # sqlite:///abs/path -> "/abs/path"; sqlite://rel.db -> "rel.db" (relative to app root)
    ;;
  mysql|mariadb)
    ENGINE="mysql" ;;
  postgres|postgresql|pgsql)
    ENGINE="postgres" ;;
  *) die "unsupported DSN scheme '${DSN_SCHEME}' (expected sqlite://, mysql://, postgres://)" ;;
esac
if [ "$ENGINE" != "sqlite" ]; then
  rest="${DSN_REST%%\?*}"
  if [ "${rest#*@}" != "$rest" ]; then
    auth="${rest%@*}"; rest="${rest#*@}"
    DSN_USER="${auth%%:*}"
    [ "$auth" = "$DSN_USER" ] || DSN_PASS="${auth#*:}"
  fi
  DSN_DB="${rest#*/}"; [ "$DSN_DB" != "$rest" ] || DSN_DB=""
  hostport="${rest%%/*}"
  DSN_HOST="${hostport%%:*}"
  [ "$hostport" = "$DSN_HOST" ] || DSN_PORT="${hostport#*:}"
  [ -n "$DSN_HOST" ] || DSN_HOST="127.0.0.1"
  [ -n "$DSN_DB" ] || die "DSN has no database name"
  unset rest auth hostport
fi

# ---------------------------------------------------------------- prepare
TS="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="$OUT_DIR/${PREFIX}${TS}.tar.gz"
GIT_COMMIT="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"

log "mode=$MODE engine=$ENGINE out=$ARCHIVE"
if [ "$ENGINE" = "sqlite" ]; then
  log "sqlite path: $DSN_DB"
else
  log "$ENGINE db='$DSN_DB' host='$DSN_HOST' port='${DSN_PORT:-default}' user='${DSN_USER:-}' (password hidden)"
fi
if [ "$DRY_RUN" = 1 ]; then
  log "dry-run: nothing written"
  exit 0
fi

have tar || die "tar not found"
mkdir -p "$OUT_DIR"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lookpress-backup.XXXXXX")"
CONSISTENT="true"
DB_METHOD=""
STOPPED_APP=""

cleanup() {
  # Make sure a stopped app is started again even if we fail mid-way.
  if [ -n "$STOPPED_APP" ]; then
    warn "restarting app after failure: $STOPPED_APP"
    start_app || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# stop/start helpers (only used for the SQLite stop-copy fallback)
stop_app() {
  if [ "$MODE" = "docker" ]; then
    docker stop "$CONTAINER" >/dev/null
    STOPPED_APP="docker:$CONTAINER"
  else
    systemctl stop "$SERVICE"
    STOPPED_APP="systemd:$SERVICE"
  fi
}
start_app() {
  case "$STOPPED_APP" in
    docker:*)  docker start "$CONTAINER" >/dev/null ;;
    systemd:*) systemctl start "$SERVICE" ;;
  esac
  STOPPED_APP=""
}

# MySQL / Postgres credentials go through files/env, never argv.
MYSQL_CNF=""
mysql_cnf() {
  MYSQL_CNF="$WORK/my.cnf"
  ( umask 077; {
      printf '[client]\nhost=%s\nuser=%s\n' "$DSN_HOST" "$DSN_USER"
      [ -z "$DSN_PORT" ] || printf 'port=%s\n' "$DSN_PORT"
      [ -z "$DSN_PASS" ] || printf 'password=%s\n' "$DSN_PASS"
    } > "$MYSQL_CNF" )
}

# ---------------------------------------------------------------- database
backup_sqlite_docker() {
  local src="$DSN_DB" tmp="/tmp/lookpress-online-backup.db"
  # 1) online backup inside the container (only if the image has sqlite3 / python3)
  if docker_container_running && docker exec "$CONTAINER" sh -c 'command -v sqlite3 >/dev/null 2>&1'; then
    log "sqlite: online .backup inside container (sqlite3)"
    docker exec "$CONTAINER" sqlite3 "$src" ".backup '$tmp'"
    docker cp "$CONTAINER:$tmp" "$(hostpath "$WORK/db.sqlite")"
    docker exec "$CONTAINER" rm -f "$tmp"
    DB_METHOD="sqlite3-online-in-container"; return
  fi
  if docker_container_running && docker exec "$CONTAINER" sh -c 'command -v python3 >/dev/null 2>&1'; then
    log "sqlite: online backup inside container (python3 sqlite3.backup)"
    docker exec "$CONTAINER" python3 -c 'import sqlite3,sys; s=sqlite3.connect(sys.argv[1]); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close(); s.close()' "$src" "$tmp"
    docker cp "$CONTAINER:$tmp" "$(hostpath "$WORK/db.sqlite")"
    docker exec "$CONTAINER" rm -f "$tmp"
    DB_METHOD="python3-online-in-container"; return
  fi
  # 2) sidecar: throw-away container mounting the app's volumes (stock image has no sqlite3).
  #    The snapshot is streamed over stdout (no host bind mount: portable to Docker Desktop/Git Bash).
  if [ -n "$SIDECAR" ]; then
    log "sqlite: online backup via sidecar image '$SIDECAR' (--volumes-from $CONTAINER)"
    docker run --rm --volumes-from "$CONTAINER" "$SIDECAR" \
      python3 -c 'import sqlite3,sys,shutil
s=sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True); d=sqlite3.connect("/tmp/snap.db"); s.backup(d); d.close(); s.close()
with open("/tmp/snap.db","rb") as f: shutil.copyfileobj(f, sys.stdout.buffer)' \
      "$src" > "$WORK/db.sqlite"
    [ "$(head -c 15 "$WORK/db.sqlite" 2>/dev/null)" = "SQLite format 3" ] || die "sidecar did not produce a valid SQLite snapshot"
    DB_METHOD="sidecar-online:$SIDECAR"; return
  fi
  # 3) stop / copy / start (consistent, brief downtime)
  if [ "$NO_STOP" = 1 ]; then
    die "no online SQLite snapshot possible (image lacks sqlite3/python3) and --no-stop given. Use --sidecar."
  fi
  if docker_container_running; then
    warn "image has no sqlite3/python3: stopping '$CONTAINER' for a consistent copy (use --sidecar to avoid downtime)"
    stop_app
  else
    log "container not running: copying db file directly"
  fi
  docker cp "$CONTAINER:$src" "$(hostpath "$WORK/db.sqlite")"
  # A cleanly closed DB has no -wal; if one exists anyway, keep it so the copy stays consistent.
  docker cp "$CONTAINER:$src-wal" "$(hostpath "$WORK/db.sqlite-wal")" 2>/dev/null || true
  [ -z "$STOPPED_APP" ] || start_app
  DB_METHOD="stop-copy-start"
}

backup_sqlite_local() {
  local src="$DSN_DB"
  case "$src" in /*) ;; *) src="$ROOT_DIR/$src" ;; esac
  [ -f "$src" ] || die "sqlite file not found: $src"
  if have sqlite3; then
    log "sqlite: online .backup (sqlite3)"
    sqlite3 "$src" ".backup '$WORK/db.sqlite'"
    DB_METHOD="sqlite3-online"; return
  fi
  if have python3 && python3 -c 'import sqlite3' 2>/dev/null; then
    log "sqlite: online backup (python3 sqlite3.backup)"
    python3 -c 'import sqlite3,sys; s=sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close(); s.close()' "$src" "$WORK/db.sqlite"
    DB_METHOD="python3-online"; return
  fi
  # stop-copy-start through systemd (needs root and a known/unique look-* unit)
  if [ "$NO_STOP" != 1 ] && have systemctl && [ "$(id -u)" = 0 ]; then
    if [ -z "$SERVICE" ]; then
      SERVICE="$(systemctl list-units --type=service --state=active --no-legend --plain 'look-*' 2>/dev/null | awk '{print $1}' || true)"
      [ "$(printf '%s\n' "$SERVICE" | grep -c .)" -le 1 ] || die "several look-* services active; pick one with --service"
    fi
    if [ -n "$SERVICE" ]; then
      warn "no sqlite3/python3 on host: stopping $SERVICE for a consistent copy"
      stop_app
      cp -p "$src" "$WORK/db.sqlite"
      [ ! -f "$src-wal" ] || cp -p "$src-wal" "$WORK/db.sqlite-wal"
      start_app
      DB_METHOD="stop-copy-start"; return
    fi
  fi
  warn "no sqlite3/python3 and no service to stop: copying the LIVE file (may be inconsistent under writes)"
  cp -p "$src" "$WORK/db.sqlite"
  [ ! -f "$src-wal" ] || cp -p "$src-wal" "$WORK/db.sqlite-wal"
  CONSISTENT="false"; DB_METHOD="live-copy-UNSAFE"
}

backup_mysql() {
  mysql_cnf
  local args=(--single-transaction --quick --routines --triggers --events --add-drop-table "$DSN_DB")
  local port=(); [ -z "$DSN_PORT" ] || port=(-P "$DSN_PORT")
  if have mysqldump; then
    log "mysql: mysqldump --single-transaction (host client)"
    mysqldump --defaults-extra-file="$MYSQL_CNF" "${args[@]}" > "$WORK/db.mysql.sql"
    DB_METHOD="mysqldump-host"; return
  fi
  # host may be a compose service / container name with the client inside
  if have docker && docker ps --format '{{.Names}}' | grep -qx -- "$DSN_HOST"; then
    log "mysql: mysqldump inside container '$DSN_HOST'"
    docker exec -i -e MYSQL_PWD="$DSN_PASS" "$DSN_HOST" \
      mysqldump -h 127.0.0.1 "${port[@]}" -u "$DSN_USER" "${args[@]}" > "$WORK/db.mysql.sql"
    DB_METHOD="mysqldump-in-container:$DSN_HOST"; return
  fi
  die "mysqldump not found (install mysql-client, or run where the DB container is reachable)"
}

backup_postgres() {
  local args=(--no-owner --no-privileges --clean --if-exists --format=plain)
  local port=(); [ -z "$DSN_PORT" ] || port=(-p "$DSN_PORT")
  if have pg_dump; then
    log "postgres: pg_dump (host client)"
    PGPASSWORD="$DSN_PASS" pg_dump -h "$DSN_HOST" "${port[@]}" -U "$DSN_USER" "${args[@]}" "$DSN_DB" > "$WORK/db.pgsql.sql"
    DB_METHOD="pg_dump-host"; return
  fi
  if have docker && docker ps --format '{{.Names}}' | grep -qx -- "$DSN_HOST"; then
    log "postgres: pg_dump inside container '$DSN_HOST'"
    docker exec -i -e PGPASSWORD="$DSN_PASS" "$DSN_HOST" \
      pg_dump -h 127.0.0.1 "${port[@]}" -U "$DSN_USER" "${args[@]}" "$DSN_DB" > "$WORK/db.pgsql.sql"
    DB_METHOD="pg_dump-in-container:$DSN_HOST"; return
  fi
  die "pg_dump not found (install postgresql-client, or run where the DB container is reachable)"
}

case "$ENGINE" in
  sqlite)   if [ "$MODE" = docker ]; then backup_sqlite_docker; else backup_sqlite_local; fi ;;
  mysql)    backup_mysql ;;
  postgres) backup_postgres ;;
esac

# ---------------------------------------------------------------- uploads
mkdir -p "$WORK/u"
if [ "$MODE" = "docker" ]; then
  log "uploads: docker cp $CONTAINER:/app/uploads"
  if ! docker cp "$CONTAINER:/app/uploads" "$(hostpath "$WORK/u")/" 2>/dev/null; then
    warn "no /app/uploads in container; archiving an empty uploads/"
    mkdir -p "$WORK/u/uploads"
  fi
else
  if [ -d "$UPLOADS_DIR" ]; then
    log "uploads: $UPLOADS_DIR"
    cp -a "$UPLOADS_DIR" "$WORK/u/uploads"
  else
    warn "uploads dir '$UPLOADS_DIR' not found; archiving an empty uploads/"
    mkdir -p "$WORK/u/uploads"
  fi
fi
tar -czf "$WORK/uploads.tar.gz" -C "$WORK/u" uploads
rm -rf "$WORK/u"

# ---------------------------------------------------------------- manifest + archive
DB_FILE="$(cd "$WORK" && ls db.* | grep -v -- '-wal$' | head -n1)"
json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
cat > "$WORK/manifest.json" <<EOF
{
  "format": 1,
  "app": "lookpress",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "mode": "$MODE",
  "engine": "$ENGINE",
  "db_file": "$DB_FILE",
  "db_method": "$(json_esc "$DB_METHOD")",
  "consistent": $CONSISTENT,
  "db_name": "$(json_esc "$DSN_DB")",
  "app_commit": "$GIT_COMMIT",
  "hostname": "$(json_esc "$(hostname 2>/dev/null || echo unknown)")"
}
EOF

MEMBERS=(manifest.json "$DB_FILE" uploads.tar.gz)
[ ! -f "$WORK/db.sqlite-wal" ] || MEMBERS+=(db.sqlite-wal)
if have sha256sum; then
  (cd "$WORK" && sha256sum "${MEMBERS[@]}" > SHA256SUMS)
  MEMBERS+=(SHA256SUMS)
elif have shasum; then
  (cd "$WORK" && shasum -a 256 "${MEMBERS[@]}" > SHA256SUMS)
  MEMBERS+=(SHA256SUMS)
fi
tar -czf "$ARCHIVE" -C "$WORK" "${MEMBERS[@]}"

# ---------------------------------------------------------------- retention (only our own files, only in --out)
if [ -n "$KEEP" ]; then
  mapfile -t OLD < <(find "$OUT_DIR" -maxdepth 1 -type f -name "${PREFIX}[0-9]*-[0-9]*.tar.gz" -print | sort -r | tail -n +$((KEEP + 1)))
  for f in "${OLD[@]:-}"; do
    [ -n "$f" ] || continue
    log "prune: $f"
    rm -f -- "$f"
  done
fi

SIZE="$(du -h "$ARCHIVE" | cut -f1)"
log "done: $ARCHIVE ($SIZE, db=$DB_METHOD, consistent=$CONSISTENT)"
[ "$CONSISTENT" = "true" ] || warn "this backup was taken from a live SQLite file without an online snapshot; verify it (sqlite3 db.sqlite 'PRAGMA integrity_check')"
printf '%s\n' "$ARCHIVE"
