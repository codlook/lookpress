#!/usr/bin/env bash
# Wait until LookPress answers on URL (setup runs first in the entrypoint), or fail with the
# container's log. Usage: ci_wait.sh URL CONTAINER
URL="${1:?url}"; CT="${2:?container}"
for i in $(seq 1 90); do
  if curl -fsS -o /dev/null "$URL/" 2>/dev/null; then echo "up after ${i}s"; exit 0; fi
  if [ "$(docker inspect -f '{{.State.Running}}' "$CT" 2>/dev/null)" != "true" ]; then break; fi
  sleep 1
done
echo "LookPress did not come up"; docker logs "$CT"; exit 1
