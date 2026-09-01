#!/bin/sh
# operator.sh — one update cycle. Runs inside the `operator` container (docker
# CLI + the socket), with the kit directory mounted at its host path and as the
# working directory.
#
# Watchtower moves IMAGES; this moves the WIRING. Every release image carries
# the kit that matches it under /app/kit — this pulls the channel image,
# extracts that kit, and when a file differs from the one on disk, copies it
# over and runs update.sh: new services start, removed ones are killed, and the
# routing row is reseeded. The bundle stops being able to drift from its own
# compose file.
#
# Idempotent and quiet: an unchanged kit is a no-op cycle, an unreachable
# registry is "try again next cycle", and an image that predates /app/kit is
# skipped rather than treated as an error. `.env` is NEVER in the synced set —
# it holds this install's keys and belongs to the machine, not to a release.
set -eu

REGISTRY="${REGISTRY:-dekelmichpalil.azurecr.io}"
IMG="$REGISTRY/payroll-onprem:${BUNDLE_VERSION:-stable}"
STAGE="/tmp/kit-stage"

docker pull -q "$IMG" >/dev/null 2>&1 || exit 0

cid="$(docker create "$IMG")"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
rm -rf "$STAGE" && mkdir -p "$STAGE"
# An image built before the kit rode along has nothing at /app/kit. Not an
# error: the next release will.
docker cp "$cid:/app/kit/." "$STAGE" 2>/dev/null || exit 0

changed=0
for f in "$STAGE"/*; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  case "$b" in .env|.env.*) continue ;; esac
  if ! cmp -s "$f" "./$b"; then
    cp "$f" "./$b"
    changed=1
    echo "operator: updated $b"
  fi
done
chmod +x ./*.sh 2>/dev/null || true

[ "$changed" -eq 1 ] || exit 0
echo "operator: kit changed — applying"
sh ./update.sh
