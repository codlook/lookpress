# LookPress dev image — pure LOOK, built against the LOOK `v2` branch.
# That branch has no published runtime image yet, so the first stage builds lk / lk-fcgi from source
# (LOOK_REF picks the branch or tag). On `main` LookPress runs on the published LOOK image (1.0.x).
ARG LOOK_REF=v2

FROM ubuntu:24.04 AS look
ARG LOOK_REF
RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates cmake g++ make libssl-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "$LOOK_REF" https://github.com/codlook/look /src \
    && cmake -S /src/cpp -B /b -DCMAKE_BUILD_TYPE=Release -DLOOK_STATIC_SSL=OFF > /dev/null \
    && cmake --build /b --target look look-fcgi -j"$(nproc)" \
    && /b/lk --version

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends libssl3t64 ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --shell /usr/sbin/nologin look
COPY --from=look /b/lk /b/lk-fcgi /usr/local/bin/

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
