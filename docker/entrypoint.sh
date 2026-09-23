#!/bin/sh
# LookPress container entrypoint.
# Init runs ONCE per data volume (a marker file). Rationale: the v1 schema
# migrations are tracked/idempotent, but setup_v2's v1->v2 row migration is NOT
# yet idempotent (re-running duplicates v2 content) — proper module-migration
# tracking is Phase 3. Until then, guard init to first-run per volume.
set -e
cd /app
export DB_DSN="${DB_DSN:-sqlite:///data/cms.db}"
mkdir -p /data /app/uploads
MARKER=/data/.lp_initialized

if [ ! -f "$MARKER" ]; then
  echo "[lookpress] first run — initializing ($DB_DSN)"
  echo "[lookpress]  1/3 v1 schema (setup.lk migrate)"
  lk setup.lk migrate
  if [ "${LOOKPRESS_SEED:-0}" = "1" ]; then
    echo "[lookpress]  2/3 demo content (setup.lk seed) — before v2 so it migrates"
    lk setup.lk seed || true
  fi
  echo "[lookpress]  3/3 v2 versioned core (setup_v2.lk) — migrates v1 rows -> v2"
  lk setup_v2.lk
  touch "$MARKER"
  echo "[lookpress] init complete"
else
  echo "[lookpress] already initialized (marker present) — skipping migrations"
fi

echo "[lookpress] serving app_v2.lk on :7400"
exec lk-fcgi --mode http --port 7400 --workers 4 app_v2.lk
