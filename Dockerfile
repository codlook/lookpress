# LookPress dev image — pure LOOK on the published LOOK runtime (no core changes).
# Base carries lk / lk-fcgi / lk-cgi and runs as the unprivileged user `look`.
FROM codlook/look:1.0.0

USER root
WORKDIR /app
COPY --chown=look:look . /app
# Data + uploads dirs owned by `look` so a fresh named volume inherits that
# ownership on first mount (the app writes cms.db / uploads as user look).
RUN mkdir -p /data /app/uploads && chown -R look:look /data /app/uploads

ENV DB_DSN=sqlite:///data/cms.db \
    LOOK_SESSION_SECURE=0

USER look
# entrypoint runs idempotent migrations (v1 schema + v2 versioned core) then serves.
ENTRYPOINT ["sh", "/app/docker/entrypoint.sh"]
