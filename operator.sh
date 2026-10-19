#!/bin/sh
# operator.sh — one update cycle. Runs inside the `operator` container (docker
# CLI + the socket), with the kit directory mounted at its host path and as the
# working directory.
#
# Each cycle asks the broker which version this install's channel serves
# (images.sh). If the running app containers already carry that version, the
# cycle ends there, without contacting the registry. If not:
#   1. pull the app image under its local name, and check it is that version
#   2. pull the connector image
#   3. copy the kit that rides in the image (/app/kit) over this directory
#   4. run update.sh: new .env keys, `compose up -d --remove-orphans`, reseed
#
# update.sh leaves the agent or the connector on its old image while it
# reports a run in flight. The next cycle finds that container stale and runs
# update.sh again, until it is idle.
#
# The version is deploy/onprem/VERSION, stored in the image's
# org.opencontainers.image.version label. `edge` builds are `<VERSION>-edge`
# and only change when VERSION is bumped, so edge installs update only then.
#
# Unattended updates off (AUTO_UPDATE_MONITOR_ONLY=true in .env): the cycle
# moves nothing and only reports an available version. Read from .env, not
# the container's environment, because update.sh never recreates the
# operator and an env change would otherwise wait for a host-run install. The
# one repair it keeps is starting what is stopped — `--no-recreate` never
# replaces a running container, so a half-applied stack comes back without
# anything moving under a run. Releases then arrive only when someone applies
# them at a chosen moment: `OPERATOR_FORCE=1 sh operator.sh` then
# `sh update.sh` (the demo's promote does this once its visitor seat is free).
#
# `.env` is never in the synced set — it belongs to the machine.
#
# The body is one function, called on the last line: step 2 can overwrite this
# file while it runs, and sh reads a script as it executes it.
set -eu

# Old releases out, every cycle. Each release leaves the one before it on disk
# — about 5 GB: the bundle and the connector — untagged once the local tag
# moves on, and nothing removed them; an install with updates off never
# cleaned either. Measured 2026-10-20: a default install held 42 images, 9 in
# use, 64 GB reclaimable; the demo box reached 98% and its Mongo died
# mid-update. Only DANGLING images go — never one a container uses, never a
# tagged one — so the running release and its local name are untouched. Runs
# after main() on every path, monitor-only included.
tidy() { docker image prune -f >/dev/null 2>&1 || true; }

# Start whatever is stopped, without pulling. Repairs an apply that was cut
# short. Never the operator itself (recreating it would kill this process
# mid-apply, the 1.2.3 outage) and never a busy agent or connector.
converge() {
  SERVICES="$(apply_services 2>/dev/null)"
  # shellcheck disable=SC2086
  [ -n "$SERVICES" ] && docker compose -f docker-compose.yml up -d $SERVICES >/dev/null 2>&1 || true
}

# Copy /app/kit out of the image and over this directory. Returns 0 when a file
# changed, 1 when nothing did or the image has no kit.
sync_kit() {
  stage="/tmp/kit-stage"
  cid="$(docker create "$1")"
  rm -rf "$stage" && mkdir -p "$stage"
  if ! docker cp "$cid:/app/kit/." "$stage" 2>/dev/null; then
    docker rm -f "$cid" >/dev/null 2>&1 || true
    return 1
  fi
  docker rm -f "$cid" >/dev/null 2>&1 || true

  changed=1
  for f in "$stage"/*; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"
    case "$b" in .env|.env.*) continue ;; esac
    if ! cmp -s "$f" "./$b"; then
      cp "$f" "./$b"
      changed=0
      echo "operator: updated $b"
    fi
  done
  chmod +x ./*.sh 2>/dev/null || true
  return "$changed"
}

main() {
  KIT_ENV="./.env"
  . ./images.sh

  channel="$(kit_channel)"

  if [ "${OPERATOR_FORCE:-}" != 1 ] && [ "$(kit_env AUTO_UPDATE_MONITOR_ONLY)" = "true" ]; then
    SERVICES="$(docker compose -f docker-compose.yml config --services | grep -vx operator | tr '\n' ' ')"
    # shellcheck disable=SC2086
    docker compose -f docker-compose.yml up -d --no-recreate $SERVICES >/dev/null 2>&1 || true
    if release_lookup "$channel" 2>/dev/null; then
      running="$(running_versions | tr '\n' ' ' | sed 's/ *$//')"
      [ "$running" = "$RELEASE_VERSION" ] \
        || echo "operator: $RELEASE_VERSION is available (running ${running:-nothing}) — monitor only, not applied"
    fi
    return 0
  fi
  if ! release_lookup "$channel"; then
    echo "operator: update check skipped this cycle"
    converge
    return 0
  fi

  running="$(running_versions | tr '\n' ' ' | sed 's/ *$//')"
  if [ "$running" = "$RELEASE_VERSION" ]; then
    stale="$(stale_services "$channel" | tr '\n' ' ')"
    if [ -n "$stale" ]; then
      echo "operator: finishing the update of ${stale% }"
      IMAGES_FETCHED=1 sh ./update.sh
      return 0
    fi
    converge
    return 0
  fi

  echo "operator: updating ${running:-nothing} -> $RELEASE_VERSION"
  fetch_image "$APP_REPO" "$channel" || return 0
  got="$(image_version "$(local_image "$APP_REPO" "$channel")")"
  if [ "$got" != "$RELEASE_VERSION" ]; then
    # The tag has not moved yet, or moved again. Next cycle asks afresh.
    echo "operator: the $channel image is ${got:-unlabelled}, expected $RELEASE_VERSION — retrying next cycle"
    return 0
  fi

  fetch_image "$CONNECTOR_REPO" "$channel" || echo "operator: connector pull failed — keeping the current one"
  sync_kit "$(local_image "$APP_REPO" "$channel")" || true
  IMAGES_FETCHED=1 sh ./update.sh
}

main "$@"
tidy
exit 0
