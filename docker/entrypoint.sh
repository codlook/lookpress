#!/bin/sh
# LookPress container entrypoint.
# Migrations run on EVERY start (idempotent): setup.lk's v1 schema and setup_v2's
# v2 schema are tracked (schema_migrations / migrate_run), and setup_v2's v1->v2 row
# migration is guarded to run only when the v2 core is empty. So adding a new table
# to setup_v2 lands on the next restart with no manual step and no duplication.
# The demo SEED runs once per data volume (a marker file), before setup_v2 so the
# seeded pages/posts migrate into the v2 core.
set -e
cd /app
export DB_DSN="${DB_DSN:-sqlite:///data/cms.db}"
mkdir -p /data /app/uploads

echo "[lookpress] migrating (idempotent) — v1 schema"
lk setup.lk migrate

if [ ! -f /data/.lp_initialized ]; then
  if [ "${LOOKPRESS_SEED:-0}" = "1" ]; then
    echo "[lookpress] first run — seeding demo content (before v2 so it migrates)"
    lk setup.lk seed || true
  fi
fi

echo "[lookpress] migrating (idempotent) — v2 versioned core + orders"
lk setup_v2.lk
touch /data/.lp_initialized

echo "[lookpress] serving app_v2.lk on :7400"
exec lk-fcgi --mode http --port 7400 --workers 4 app_v2.lk
