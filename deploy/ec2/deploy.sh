#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE_TAG="${1:?usage: deploy.sh sha-<7-hex> }"
if [[ ! "$IMAGE_TAG" =~ ^sha-[0-9a-f]{7}$ ]]; then
  echo "Refusing image tag outside sha-<7-hex> format" >&2
  exit 2
fi

cd /opt/buzz
[[ -f .env ]] || { echo "Missing /opt/buzz/.env" >&2; exit 2; }
NEW_IMAGE="ghcr.io/davidh03/buzz:${IMAGE_TAG}"
OLD_IMAGE=$(python3 -c 'from pathlib import Path; print(next((x.split("=",1)[1] for x in Path(".env").read_text().splitlines() if x.startswith("BUZZ_IMAGE=")), ""))')
[[ -n "$OLD_IMAGE" ]] || { echo "BUZZ_IMAGE is missing from .env" >&2; exit 2; }

compose=(docker compose --env-file .env -f compose.yml -f compose.minio-mirror.yml -f compose.pair.yml -f compose.caddy.yml)
backup=$(mktemp /opt/buzz/.env.deploy-backup.XXXXXX)
cp -p .env "$backup"
chmod 0600 "$backup"
rollback() {
  rc=$?
  if [[ $rc -ne 0 && -n "${backup:-}" && -f "$backup" ]]; then
    echo "Deployment failed; restoring previous Buzz image setting" >&2
    cp -p "$backup" .env
    "${compose[@]}" pull relay pair-relay || true
    "${compose[@]}" up -d --no-deps --force-recreate --pull never --wait relay pair-relay || true
  fi
  if [[ -n "${backup:-}" && -f "$backup" ]]; then rm -f "$backup"; fi
  exit "$rc"
}
trap rollback EXIT

# Pull first; a missing/private package fails before the running stack changes.
docker pull "$NEW_IMAGE" >/dev/null
python3 - "$NEW_IMAGE" <<'PY'
from pathlib import Path
import os, sys, tempfile
path = Path("/opt/buzz/.env")
image = sys.argv[1]
lines = path.read_text().splitlines()
found = False
updated = []
for line in lines:
    if line.startswith("BUZZ_IMAGE="):
        updated.append("BUZZ_IMAGE=" + image)
        found = True
    else:
        updated.append(line)
if not found:
    updated.append("BUZZ_IMAGE=" + image)
fd, tmp = tempfile.mkstemp(prefix=".env.deploy.", dir=str(path.parent))
try:
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(updated) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY

"${compose[@]}" config --quiet
"${compose[@]}" pull relay pair-relay >/dev/null
"${compose[@]}" up -d --no-deps --force-recreate --pull never --wait relay pair-relay
# Reload Caddy after refreshing the version-controlled route config.
docker exec buzz-prod-caddy-1 caddy reload --config /etc/caddy/Caddyfile >/dev/null
relay_health=$(docker inspect --format '{{.State.Health.Status}}' buzz-prod-relay-1)
relay_image=$(docker inspect --format '{{.Config.Image}}' buzz-prod-relay-1)
pair_image=$(docker inspect --format '{{.Config.Image}}' buzz-prod-pair-relay-1)
[[ "$relay_health" == healthy && "$relay_image" == "$NEW_IMAGE" && "$pair_image" == "$NEW_IMAGE" ]]
printf 'Buzz deployed: %s; relay health=%s; pair-relay image matches.\n' "$IMAGE_TAG" "$relay_health"
rm -f "$backup"
backup=""
trap - EXIT
