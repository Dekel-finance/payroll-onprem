#!/bin/sh
# update.sh — apply THIS kit to the running install.
#
# The release's own migration step. It runs in two places and must work in
# both: on the host via `./install.sh update`, and inside the `operator`
# container after it syncs a newer kit out of the release image. Plain POSIX
# sh, no bash-isms, nothing but docker + coreutils.
#
# Everything here is idempotent — the whole point is that running it after
# every release is safe, so a release that needs no migration costs nothing.
set -eu

cd "$(dirname "$0")"

# ── .env keys this version of the bundle needs ───────────────────────────────
#
# Appended only when missing; an existing value is NEVER touched — two of these
# seal data at rest, and regenerating one turns what it sealed into noise.
rand_hex() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
rand_b64url() { head -c "$1" /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n'; }
ensure() {
  grep -q "^$1=" .env 2>/dev/null || { printf '%s=%s\n' "$1" "$2" >> .env; echo "update: added $1 to .env"; }
}

# The connector's bearer (default-on since 1.1.19 — an on-prem install exists
# because there is a payroll machine to drive).
ensure WORKER_TOKEN "$(rand_hex)"
# The stored-credential keyring: seals the RDP password the office types into
# settings. Installs from before it shipped have no key and cannot save.
ensure SECRET_KEYS "v1:$(rand_b64url 32)"
ensure SECRET_ACTIVE_KEY "v1"
# Where this kit lives on the host — the operator mounts it at the same path,
# which is what lets compose-in-a-container resolve ./Caddyfile and .env.
ensure KIT_DIR "$(pwd)"

# ── Images ───────────────────────────────────────────────────────────────────
#
# Pulled through images.sh: the broker gives the registry address for this
# pull only, and the images are kept under their local payroll.invalid names.
# The operator has already pulled when it calls this (IMAGES_FETCHED=1); run
# any other way, this pulls both images.
#
# A failed pull is not a failed update: the install applies the kit with the
# images it has. adopt_legacy_images covers an install from before images.sh,
# whose images exist only under their registry names.
KIT_ENV="./.env"
. ./images.sh
channel="$(kit_channel)"
if [ "${IMAGES_FETCHED:-}" != "1" ]; then
  if release_lookup "$channel"; then
    fetch_image "$APP_REPO" "$channel" || echo "update: app image pull failed — applying with the local one"
    fetch_image "$CONNECTOR_REPO" "$channel" || echo "update: connector pull failed — applying with the local one"
  else
    echo "update: release check failed — applying with local images"
  fi
fi
adopt_legacy_images "$channel"
pin_mongo_version

# ── Apply the wiring ─────────────────────────────────────────────────────────
#
# NEVER the operator itself. This script runs INSIDE the operator container,
# and an `up` that decides to recreate it (a moved docker-cli digest is
# enough) kills the compose process mid-apply — half the stack stopped, no
# error anywhere, and the next cycle sees no file diff to notice it by. That
# was the 1.2.3 outage. The operator's own definition changes apply on the
# next host-run ./install.sh update, whose compose is not sawing its own
# branch.
#
# Never a busy agent or connector either: restarting one mid-run loses the
# run (images.sh, apply_services). It stays on its old image and the next
# operator cycle, which sees it stale, runs this again.
#
# `--remove-orphans` is the "kill old services" half of the contract: a service
# a release removed from this file is stopped, not left running for ever (this
# is how `watchtower` goes away). Volumes are never touched — data outlives
# topology.
# Busy services are named on stderr, which goes to the operator's log.
SERVICES="$(apply_services)"
# Third-party images only (mongo, caddy, guacd, busybox): ours are
# `pull_policy: never` and compose skips them.
# shellcheck disable=SC2086
docker compose -f docker-compose.yml pull --quiet --ignore-pull-failures $SERVICES || echo "update: pull failed — applying with local images"
# One immediate retry: a container recreated by something else while this
# `up` walks the stack fails it with "No such container" — and the half that
# was already stopped stays stopped until the next cycle, ten minutes later
# (demo, 2026-10-19). The second `up` sees the settled state and finishes.
# shellcheck disable=SC2086
docker compose -f docker-compose.yml up -d --remove-orphans $SERVICES || {
  echo "update: up failed — retrying once"
  sleep 5
  # shellcheck disable=SC2086
  docker compose -f docker-compose.yml up -d --remove-orphans $SERVICES
}

# The containers now run the local names: drop the registry-named copies and
# images nothing uses any more.
remove_legacy_images

# ── Reseed the rows the applications resolve at runtime ──────────────────────
#
# Idempotent upserts (register-install.mjs): the agency, the connector routing
# row — including repairing the empty-baseUrl row an older installer left —
# and nothing it was not told. `|| true`: a reseed that loses the race with a
# console still starting is repaired by the next cycle, not a failed update.
docker compose cp register-install.mjs console:/app/register-install.mjs >/dev/null 2>&1 || true
docker compose exec -T console node /app/register-install.mjs || echo "update: reseed skipped (console not ready — next cycle repairs it)"

# The release this replaced, off the disk — the same dangling-only prune the
# operator runs every cycle (see operator.sh), for a host-run update too.
docker image prune -f >/dev/null 2>&1 || true
echo "update: applied"
