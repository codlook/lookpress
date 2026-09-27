#!/usr/bin/env bash
# Reset a public LookPress demo to its freshly seeded state.
#
# Backs up the current database, removes it and the uploads, re-runs the
# migrations and the demo seed as the site's system user, and restarts the
# service. Meant for a nightly cron on a demo site whose admin account is public.
#
#   demo-reset.sh --root DIR --user USER --service NAME [--keep N] [--lk PATH]
#
# Only SQLite installs are supported (DB_DSN=sqlite:///...); anything else exits.
set -euo pipefail
umask 077

ROOT=""; RUN_AS=""; SERVICE=""; KEEP=7; LK="/opt/look/lk"
BACKUP_DIR="/root/lookpress-backups"

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --root)    ROOT="${2:?--root needs a value}"; shift 2 ;;
    --user)    RUN_AS="${2:?--user needs a value}"; shift 2 ;;
    --service) SERVICE="${2:?--service needs a value}"; shift 2 ;;
    --keep)    KEEP="${2:?--keep needs a value}"; shift 2 ;;
    --lk)      LK="${2:?--lk needs a value}"; shift 2 ;;
    --backup-dir) BACKUP_DIR="${2:?--backup-dir needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$ROOT" ] && [ -n "$RUN_AS" ] && [ -n "$SERVICE" ] || { usage >&2; exit 2; }
[ -f "$ROOT/app.lk" ] || { echo "not a LookPress root: $ROOT" >&2; exit 1; }
[ -f "$ROOT/.look.env" ] || { echo "missing $ROOT/.look.env" >&2; exit 1; }

DSN=$(grep -E '^DB_DSN=' "$ROOT/.look.env" | head -1 | cut -d= -f2-)
case "$DSN" in
  sqlite://*) DB_FILE="${DSN#sqlite://}" ;;
  *) echo "demo-reset supports SQLite only" >&2; exit 1 ;;
esac
# The database must live inside the site root; refuse anything else.
case "$DB_FILE" in
  "$ROOT"/*) : ;;
  *) echo "database is outside the site root, refusing: $DB_FILE" >&2; exit 1 ;;
esac

TS=$(date +%Y%m%d-%H%M%S)
mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"

started=0
restart() { if [ "$started" = 0 ]; then systemctl start "$SERVICE" || true; fi; }
trap restart EXIT

systemctl stop "$SERVICE"

if [ -f "$DB_FILE" ]; then
  cp -a "$DB_FILE" "$BACKUP_DIR/demo-reset-$TS.db"
fi
rm -f "$DB_FILE" "$DB_FILE-wal" "$DB_FILE-shm"
if [ -d "$ROOT/uploads" ]; then
  find "$ROOT/uploads" -mindepth 1 -delete
fi
rm -rf "$ROOT/.look_cache"

run() { sudo -u "$RUN_AS" bash -c "cd '$ROOT' && env \$(grep -v '^#' .look.env | xargs -d '\n') LOOKPRESS_SEED=1 '$LK' $1"; }
run "setup.lk migrate" >/dev/null
run "setup.lk seed"    >/dev/null || true
run "setup_v2.lk"      >/dev/null

chown -R "$RUN_AS" "$(dirname "$DB_FILE")" "$ROOT/uploads" 2>/dev/null || true

systemctl start "$SERVICE"; started=1

# Retention: only our own reset snapshots.
ls -1t "$BACKUP_DIR"/demo-reset-*.db 2>/dev/null | tail -n +"$((KEEP + 1))" | while read -r f; do rm -f "$f"; done

echo "demo reset done at $TS"
