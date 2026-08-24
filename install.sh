#!/usr/bin/env bash
# install.sh — stand the payroll platform up on this machine.
#
#   ./install.sh check      what this machine is missing, and nothing else
#   ./install.sh install    the whole thing: secrets, images, containers, first user
#   ./install.sh status     what is running, and the addresses to open
#   ./install.sh update     pull a newer version and restart
#   ./install.sh backup     a database dump you can carry away
#   ./install.sh stop       stop everything (your data survives)
#
# It is safe to run `install` more than once. Secrets are generated on the first
# run only, and re-running repairs a half-finished install rather than starting
# a new one.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

ENV_FILE="$HERE/.env"
REGISTRY="${REGISTRY:-dekelmichpalil.azurecr.io}"
COMPOSE=(docker compose)
BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'

say()  { printf '%s\n' "$*"; }
step() { printf '\n%s▸ %s%s\n' "$BOLD" "$*" "$OFF"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$OFF" "$*"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$OFF" "$*"; }
die()  { printf '\n  %s✗ %s%s\n\n' "$RED" "$*" "$OFF" >&2; exit 1; }

# ── What this machine has to be ──────────────────────────────────────────────
#
# Checked before anything is written, because the failures these produce are all
# obscure: an old compose reports a schema error on a valid file, and a machine
# short of memory kills the Mongo container an hour in, under load, with an
# exit code that names nothing.
cmd_check() {
  local fail=0

  step "Docker"
  if command -v docker >/dev/null 2>&1; then
    ok "docker $(docker --version | awk '{print $3}' | tr -d ,)"
  else
    warn "docker is not installed — https://docs.docker.com/engine/install/"; fail=1
  fi

  if docker compose version >/dev/null 2>&1; then
    local v; v="$(docker compose version --short 2>/dev/null || echo 0)"
    ok "docker compose $v"
    # `!reset` in the TLS overlay, and `depends_on: condition:` throughout, both
    # need a v2 compose. The standalone `docker-compose` v1 binary parses this
    # file and starts the wrong thing.
    case "$v" in
      2.2[0-9]*|2.[3-9][0-9]*|[3-9]*) : ;;
      *) warn "compose $v is older than 2.20 — upgrade before installing"; fail=1 ;;
    esac
  else
    warn "the docker compose plugin is missing (v1 'docker-compose' is not enough)"; fail=1
  fi

  if docker info >/dev/null 2>&1; then
    ok "the docker daemon is reachable"
  else
    warn "cannot talk to the docker daemon — is it running, and is this user in the 'docker' group?"; fail=1
  fi

  step "Machine"
  local cores mem_gb disk_gb
  cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)"
  if [ "$cores" -ge 4 ]; then ok "$cores CPU cores"; else warn "$cores CPU cores — 4 is the practical minimum"; fi

  if [ -r /proc/meminfo ]; then
    mem_gb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
    if [ "$mem_gb" -ge 8 ]; then ok "${mem_gb}GB RAM"; else warn "${mem_gb}GB RAM — 8GB is the minimum, 16GB is comfortable"; fi
  fi

  # -P/-k rather than GNU's -BG: on a BSD/macOS box the GNU flags fail and the
  # figure comes back empty, which reads as "0GB free" and stops an install that
  # was fine.
  disk_gb=$(df -Pk "$HERE" 2>/dev/null | awk 'NR==2 {print int($4/1024/1024)}')
  if [ "${disk_gb:-0}" -ge 40 ]; then ok "${disk_gb}GB free disk"
  else warn "${disk_gb}GB free — the images alone are ~6GB and the database grows"; fi

  step "Network"
  # Only two hosts need to be reachable, and saying so is half the point of this
  # check: a security team asking "what does it call out to?" gets a two-line
  # answer rather than a shrug.
  for host in "$REGISTRY" api.anthropic.com; do
    # ANY http status means the host answered. Both of these reply 401 to an
    # unauthenticated request, so `curl -f` — which fails on 4xx — would report a
    # blocked firewall on a perfectly good connection and send an IT department
    # after a problem that does not exist. `000` is the only real failure.
    local code; code="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "https://$host/v2/" 2>/dev/null || echo 000)"
    if [ "$code" != "000" ]; then
      ok "$host is reachable"
    else
      warn "$host did not answer — a proxy or firewall may need to allow it"; fail=1
    fi
  done

  step "Ports"
  for p in "${CONSOLE_PORT:-4201}" "${ADMIN_PORT:-4301}" "${PORTAL_PORT:-4401}"; do
    if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":$p "; then
      warn "port $p is already in use — set a different one in .env"; fail=1
    else
      ok "port $p is free"
    fi
  done

  [ "$fail" -eq 0 ] || die "fix the items marked ! above, then run './install.sh check' again"
  say ""
  ok "this machine is ready — run ./install.sh install"
}

rand_hex() { openssl rand -hex 32; }

# ── Secrets ──────────────────────────────────────────────────────────────────
#
# Written once. Two of them seal data at rest, and regenerating either turns
# everything already stored into noise — so an existing .env is never touched,
# and this refuses to guess which of two files was the real one.
write_env() {
  if [ -f "$ENV_FILE" ]; then
    ok ".env already exists — keeping it (your keys are in there)"
    return
  fi
  step "Generating this install's secrets"
  cat > "$ENV_FILE" <<EOF
# Generated by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ). KEEP A COPY OFF THIS MACHINE.
#
# PORTAL_FILE_KEK seals every employee document and NATIONAL_ID_KEYS is what
# makes an identity number readable. Lose this file and the data in the volumes
# is unrecoverable — there is no reset, by design.

DEPLOY_TARGET=onprem
BUNDLE_VERSION=stable
MONGODB_DB=payroll

GATEWAY_TOKEN=$(rand_hex)
INTERNAL_TOKEN=$(rand_hex)
CRON_SECRET=$(rand_hex)
WORKER_TOKEN=$(rand_hex)
PORTAL_FILE_KEK=$(openssl rand -base64 32)
NATIONAL_ID_KEYS=v1:$(openssl rand -base64 64 | tr '+/' '-_' | tr -d '=\n')
NATIONAL_ID_ACTIVE_KEY=v1

# Who this install is, in our fleet. An opaque handle, not your company name.
METRICS_INSTALL_ID=${INSTALL_ID:-install-$(openssl rand -hex 4)}
METRICS_HASH_SALT=$(rand_hex)
METRICS_CONTROL_PLANE_URL=
METRICS_INSTALL_TOKEN=

# ── Fill these in ────────────────────────────────────────────────────────────

# The model vendor key. Held ONLY by the gateway container; the applications
# never see it and cannot reach a vendor directly.
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
INTERFAZE_API_KEY=${INTERFAZE_API_KEY:-}

# The Windows machine on your network that runs מיכפל. Leave blank if you are
# not using the connector.
RDP_HOST=${RDP_HOST:-}
RDP_USER=${RDP_USER:-payrolladmin}
RDP_PASS=${RDP_PASS:-}

# Telemetry we receive: counts, durations and error codes. Never a name, a
# document or an error message. Blank = this install reports nothing.
BETTERSTACK_INGEST_HOST=${BETTERSTACK_INGEST_HOST:-}
BETTERSTACK_SOURCE_TOKEN=${BETTERSTACK_SOURCE_TOKEN:-}
BETTERSTACK_HEARTBEAT_URL=${BETTERSTACK_HEARTBEAT_URL:-}

GATEWAY_MODE=enforce
GATEWAY_KINDS=email,id,phone,person,org
GATEWAY_ATTACHMENTS=block

# Checked every AUTO_UPDATE_INTERVAL seconds against the registry. `stable` is a
# channel we move deliberately, which is what makes an unattended update safe;
# pin an exact version instead and updates simply never fire.
AUTO_UPDATE_INTERVAL=${AUTO_UPDATE_INTERVAL:-600}
AUTO_UPDATE_MONITOR_ONLY=${AUTO_UPDATE_MONITOR_ONLY:-false}
AUTO_UPDATE_CONNECTOR=${AUTO_UPDATE_CONNECTOR:-false}

CONSOLE_PORT=${CONSOLE_PORT:-4201}
ADMIN_PORT=${ADMIN_PORT:-4301}
# Which interface the admin port is published on. `127.0.0.1` means the admin
# application runs but no browser on your network can reach it — it is the
# supplier's back office, and the console covers everything you need. Support
# reaches it through an SSH tunnel:
#   ssh -L 4301:127.0.0.1:4301 <this host>   then https://localhost:4301
ADMIN_BIND=${ADMIN_BIND:-127.0.0.1}
PORTAL_PORT=${PORTAL_PORT:-4401}
BACKUP_DIR=./backups

# The address staff will type. A hostname on your network, or this machine's IP.
SITE_ADDRESS=${SITE_ADDRESS:-localhost}

# Which certificate Caddy issues.
#   Caddyfile.lan     its own CA — any hostname or IP, no internet needed. The
#                     default; staff trust the CA once (see the README).
#   Caddyfile.public  Let's Encrypt, only if SITE_ADDRESS resolves from the
#                     internet and port 80 is reachable.
CADDYFILE=${CADDYFILE:-Caddyfile.lan}
ACME_EMAIL=

# Port 80 is used for ONE thing: Let's Encrypt's HTTP-01 challenge. A LAN
# install never performs it, and claiming a port the server may already be using
# for something else is how an install fails on a machine that was fine. `0`
# lets Docker pick an unused one.
ACME_PORT=${ACME_PORT:-0}
EOF
  chmod 600 "$ENV_FILE"
  ok "wrote .env — ${BOLD}back this file up now${OFF}"
}

# One compose file. Which certificate Caddy issues is CADDYFILE in .env, not a
# second file to remember to pass.
dc() {
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -a; . "$ENV_FILE"; set +a
  fi
  "${COMPOSE[@]}" -f docker-compose.yml --profile "${PROFILE:-michpal}" "$@"
}

cmd_install() {
  cmd_check
  write_env
  # shellcheck disable=SC1090
  set -a && . "$ENV_FILE" && set +a

  step "Pulling the images"
  # No credentials: the registry serves these anonymously. If this ever fails,
  # it is the network between here and the registry, not a login.
  if ! docker pull -q "${PAYROLL_IMAGE:-$REGISTRY/payroll-onprem}:${BUNDLE_VERSION:-stable}"; then
    die "could not reach $REGISTRY — check the proxy or firewall, then run ./install.sh install again"
  fi
  ok "images are local"

  step "Starting"
  mkdir -p backups
  dc up -d
  ok "containers started"

  step "Waiting for the database and the applications"
  local tries=0
  until dc ps --format '{{.Service}} {{.Status}}' 2>/dev/null | grep -q "console.*healthy"; do
    tries=$((tries + 1)); [ "$tries" -gt 60 ] && die "the console did not become healthy — ./install.sh logs console"
    sleep 5
  done
  ok "the console is healthy"

  cmd_bootstrap
  cmd_status
}

# ── The four things an install cannot know about itself ──────────────────────
cmd_bootstrap() {
  # shellcheck disable=SC1090
  set -a && . "$ENV_FILE" && set +a
  local email="${FIRST_USER_EMAIL:-}" pass="${FIRST_USER_PASSWORD:-}"
  if [ -z "$email" ]; then
    read -r -p "  Email address for the first administrator: " email
  fi
  if [ -z "$pass" ]; then
    read -r -s -p "  Choose a password for it: " pass; echo
  fi
  [ -n "$email" ] && [ -n "$pass" ] || die "an install with no user cannot be signed into, and nothing else can create one"

  step "Registering the agency, the portal address, the connector and the first user"
  # Copied to /app rather than /tmp: node resolves its dependencies by walking up
  # from the script, and from /tmp it never reaches the application's modules.
  dc cp register-install.mjs console:/app/register-install.mjs >/dev/null
  dc exec -T \
    -e AGENCY_NAME="${AGENCY_NAME:-}" \
    -e PORTAL_HOST="${SITE_ADDRESS:-localhost}" \
    -e FIRST_USER_EMAIL="$email" \
    -e FIRST_USER_PASSWORD="$pass" \
    console node /app/register-install.mjs
}

cmd_status() {
  # shellcheck disable=SC1090
  set -a && . "$ENV_FILE" && set +a
  dc ps
  local scheme=https host="${SITE_ADDRESS:-localhost}"
  say ""
  say "  ${BOLD}Console${OFF}  $scheme://$host:${CONSOLE_PORT:-4201}   ${DIM}the payroll office${OFF}"
  say "  ${BOLD}Portal${OFF}   $scheme://$host:${PORTAL_PORT:-4401}   ${DIM}where employees sign in${OFF}"
  say ""
}

cmd_update() {
  # shellcheck disable=SC1090
  set -a && . "$ENV_FILE" && set +a
  step "Pulling ${BUNDLE_VERSION:-stable}"
  dc pull
  dc up -d
  ok "updated — your data was not touched"
  # Images move on `pull`; the compose file and this script do not. A change to
  # how the install is wired (a port, a new service) arrives with a `git pull`
  # in this directory, and an install that never pulls keeps its old wiring
  # while reporting the new version.
  say "  ${DIM}configuration changes arrive with: git pull && ./install.sh update${OFF}"
  cmd_status
}

# ── Backup ───────────────────────────────────────────────────────────────────
#
# The database AND the documents. A dump on its own restores an install where
# every employee exists and none of their files open, which is the kind of
# backup people discover the shape of during a restore.
cmd_backup() {
  local stamp; stamp="$(date -u +%Y%m%d-%H%M%S)"
  mkdir -p "backups/$stamp"
  step "Dumping the database"
  dc exec -T mongo mongodump --archive --gzip --db "${MONGODB_DB:-payroll}" > "backups/$stamp/payroll.archive.gz"
  ok "backups/$stamp/payroll.archive.gz"
  step "Copying the documents"
  docker run --rm \
    -v payroll-onprem_portal-files:/portal:ro \
    -v payroll-onprem_console-files:/console:ro \
    -v "$PWD/backups/$stamp:/out" \
    alpine tar czf /out/documents.tar.gz -C / portal console
  ok "backups/$stamp/documents.tar.gz"
  warn "your .env holds the keys these files are sealed with — back that up separately, and not beside them"
}

cmd_logs() { dc logs --tail="${TAIL:-100}" -f "${1:-}"; }
cmd_stop() { dc down; ok "stopped — the data volumes are untouched"; }

case "${1:-}" in
  check)     cmd_check ;;
  install)   cmd_install ;;
  bootstrap) cmd_bootstrap ;;
  status)    cmd_status ;;
  update)    cmd_update ;;
  backup)    cmd_backup ;;
  logs)      shift; cmd_logs "${1:-}" ;;
  stop)      cmd_stop ;;
  *)         sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 64 ;;
esac
