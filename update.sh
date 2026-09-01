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

# ── Apply the wiring ─────────────────────────────────────────────────────────
#
# Pull first: the services watchtower deliberately never touches (the
# connector) move at exactly these moments — a release that changed the kit is
# a chosen moment, not an unattended 03:00 restart mid-payroll-run.
# `--remove-orphans` is the "kill old services" half of the contract: a service
# a release removed from this file is stopped, not left running for ever.
# Volumes are never touched — data outlives topology.
docker compose -f docker-compose.yml pull --quiet || echo "update: pull failed — applying with local images"
docker compose -f docker-compose.yml up -d --remove-orphans

# ── Reseed the rows the applications resolve at runtime ──────────────────────
#
# Idempotent upserts (register-install.mjs): the agency, the connector routing
# row — including repairing the empty-baseUrl row an older installer left —
# and nothing it was not told. `|| true`: a reseed that loses the race with a
# console still starting is repaired by the next cycle, not a failed update.
docker compose cp register-install.mjs console:/app/register-install.mjs >/dev/null 2>&1 || true
docker compose exec -T console node /app/register-install.mjs || echo "update: reseed skipped (console not ready — next cycle repairs it)"

echo "update: applied"
