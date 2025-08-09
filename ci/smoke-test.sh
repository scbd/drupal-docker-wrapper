#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <image-tag>" >&2
  exit 1
fi

IMAGE="$1"
echo "[smoke-test] Starting container from image: $IMAGE"
container_id=$(docker run -d "$IMAGE")
trap 'docker rm -f "$container_id" >/dev/null 2>&1 || true' EXIT

# Allow services (Apache/PHP) to initialize
sleep 12

echo "[smoke-test] Checking PHP version"
docker exec "$container_id" bash -lc 'php -v'

echo "[smoke-test] Checking Drush availability"
docker exec "$container_id" bash -lc 'vendor/bin/drush --version'

echo "[smoke-test] Verifying key contrib modules present"
modules=(jsonapi_extras search_api)
for m in "${modules[@]}"; do
  docker exec "$container_id" bash -lc "test -d web/modules/contrib/$m" || { echo "Missing module directory: $m" >&2; exit 2; }
done

echo "[smoke-test] All checks passed for $IMAGE"
