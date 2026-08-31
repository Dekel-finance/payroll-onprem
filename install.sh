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
  local cores mem_gb disk_gb arch

  # AVX, and it is a hard stop rather than a warning.
  #
  # MongoDB 5.0 and later are compiled with AVX instructions; a CPU without them
  # does not run the database slowly, it does not run it at all — the container
  # exits and the log says only:
  #
  #   WARNING: MongoDB 5.0+ requires a CPU with AVX support, and your current
  #   system does not appear to have that!
  #
  # Which is easy to miss in a wall of pulling output, and leaves an install
  # where every other container is healthy. The usual cause is not old hardware:
  # it is a hypervisor presenting a generic CPU model (`qemu64`, `kvm64`, an old
  # Hyper-V compatibility level) that masks the flag the host actually has. Set
  # the guest CPU to `host` — or `host-passthrough` — and it appears.
  arch="$(uname -m 2>/dev/null || echo unknown)"
  case "$arch" in
    x86_64|amd64)
      if [ -r /proc/cpuinfo ]; then
        if grep -qm1 '\bavx\b' /proc/cpuinfo; then
          ok "the CPU supports AVX"
        else
          warn "this CPU reports no AVX — MongoDB 5.0+ will not start on it. If this is a VM, set its CPU model to host/host-passthrough."; fail=1
        fi
      else
        warn "cannot read /proc/cpuinfo — AVX not verified; if the database will not start, this is why"
      fi
      ;;
    *) ok "$arch — AVX does not apply on this architecture" ;;
  esac

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
  for host in "$REGISTRY" dekel.sh broker.dekel.io; do
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
  for p in "${CONSOLE_PORT:-443}" "${ADMIN_PORT:-3300}"; do
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

# The first user's password, generated rather than asked for.
#
# Twelve characters in three groups, from an alphabet with no `l`, `1`, `O` or
# `0` in it — this gets read off a terminal by one person and typed into a
# browser by another, and the ambiguous pair costs more support time than the
# entropy it buys. ~69 bits, which is a long way past anything that matters for
# a credential meant to be changed at the first sign-in.
#
# `cut`, not `head -c`: head closes the pipe early, openssl takes SIGPIPE, and
# `set -o pipefail` turns a perfectly good password into a failed install.
rand_password() {
  local raw
  raw="$(openssl rand -base64 96 | LC_ALL=C tr -dc 'A-HJ-NP-Za-km-z2-9' | cut -c1-12)"
  printf '%s-%s-%s' "${raw:0:4}" "${raw:4:4}" "${raw:8:4}"
}

# The address that first user signs in with.
#
# Derived, not asked for. A bureau that wants a real person's address sets
# FIRST_USER_EMAIL; everyone else gets an account that works and renames itself
# later from inside the console. It has to LOOK like an address — the login form
# validates one — so a SITE_ADDRESS that is an IP or a bare `localhost` falls
# back to a name that is always well-formed and never routable.
first_user_email() {
  # A hostname with a dot in it, and not an IP address — `10.0.0.5` and a bare
  # `localhost` both fall through to the well-formed default.
  case "${SITE_ADDRESS:-}" in
    *[!0-9.]*.*) printf 'admin@%s' "$SITE_ADDRESS" ;;
    *)           printf 'admin@payroll.local' ;;
  esac
}

# This install's mail keypair — the private half, and it is generated HERE.
#
# The arrangement it makes possible: we hold only the public half, so a message
# parked on our side for this install is sealed to a key we do not have. That is
# a property of where the key was made, not a promise about our conduct, and it
# only holds if the key is never generated anywhere but on this machine.
#
# An x25519 private key in DER is a 16-byte PKCS#8 preamble followed by the 32
# bytes that matter; `tail -c 32` takes the second part. base64url because the
# value has to survive being a line in a `.env` file.
rand_x25519() { openssl genpkey -algorithm x25519 -outform DER | tail -c 32 | openssl base64 -A | tr '+/' '-_' | tr -d '='; }

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
# NATIONAL_ID_KEYS is what makes an identity number readable. Lose this file and
# the data in the volumes is unrecoverable — there is no reset, by design.

DEPLOY_TARGET=onprem
BUNDLE_VERSION=stable
MONGODB_DB=payroll

GATEWAY_TOKEN=$(rand_hex)
INTERNAL_TOKEN=$(rand_hex)
CRON_SECRET=$(rand_hex)
WORKER_TOKEN=$(rand_hex)
NATIONAL_ID_KEYS=v1:$(openssl rand -base64 64 | tr '+/' '-_' | tr -d '=\n')
NATIONAL_ID_ACTIVE_KEY=v1
# The stored-credential keyring (AES-256): the RDP password the office types
# into the console's settings is sealed with this before it touches the
# database. Same custody rule as NATIONAL_ID_KEYS.
SECRET_KEYS=v1:$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')
SECRET_ACTIVE_KEY=v1

# Who this install is, in our fleet. An opaque handle, not your company name.
METRICS_INSTALL_ID=${INSTALL_ID:-install-$(openssl rand -hex 4)}
METRICS_HASH_SALT=$(rand_hex)
# The control plane's and the model broker's addresses are compiled into the
# image — leave these blank. The TOKEN is the one value we send you, and it is
# what lets this install report its health AND collect your inbound email.
METRICS_CONTROL_PLANE_URL=
METRICS_INSTALL_TOKEN=${INSTALL_TOKEN:-}
MODEL_BROKER_URL=
MODEL_BROKER_TOKEN=${INSTALL_TOKEN:-}

# Inbound and outbound email, through the same door as everything else.
#
# `relay` is the default and not a decision we ask you to make, because `off` is
# not a smaller version of this install — it is one where the office has no
# address clients can write to AND no invitation email can be sent, including
# the one that adds your second member of staff. There is still no inbound hole:
# nothing connects to this machine. The gateway polls for mail it can open, and
# only it can open it.
#
# MAIL_INSTALL_PRIVATE_KEY is generated on this machine and never leaves it. Its
# public half is derived and published by the gateway at boot; we are told that
# half and nothing else. Losing this key makes every message parked for this
# install permanently unreadable — back it up with NATIONAL_ID_KEYS.
MAIL_INBOUND_MODE=${MAIL_INBOUND_MODE:-relay}
MAIL_INSTALL_PRIVATE_KEY=$(rand_x25519)

# ── Fill these in ────────────────────────────────────────────────────────────

# The model vendor key. Held ONLY by the gateway container; the applications
# never see it and cannot reach a vendor directly.
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
INTERFAZE_API_KEY=${INTERFAZE_API_KEY:-}

# The Windows machine on your network that runs מיכפל. Leave blank if you are
# not using the connector.
# The payroll connector runs on our infrastructure, not here. If we ask you
# to use one, we send you its address and bearer.
MICHPAL_WORKER_URL=${MICHPAL_WORKER_URL:-}

# The first user of the console. Generated here rather than asked for: an
# installer that stops to interview somebody is an installer that cannot be run
# by a script, and the account is renamed from inside the console anyway. Set
# FIRST_USER_EMAIL/FIRST_USER_PASSWORD before installing to choose your own.
FIRST_USER_EMAIL=${FIRST_USER_EMAIL:-$(first_user_email)}
FIRST_USER_PASSWORD=${FIRST_USER_PASSWORD:-$(rand_password)}

# Application logs and traces: counts, durations, error codes and hashed
# identifiers, checked against an allow-list before they are sent. Never a name,
# a document or an error message. Part of the install, like the health rollup —
# these two lines are sent to you with the install id and token.
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

CONSOLE_PORT=${CONSOLE_PORT:-443}
ADMIN_PORT=${ADMIN_PORT:-4301}
# Which interface the admin port is published on. `127.0.0.1` means the admin
# application runs but no browser on your network can reach it — it is the
# supplier's back office, and the console covers everything you need. Support
# reaches it through an SSH tunnel:
#   ssh -L 4301:127.0.0.1:4301 <this host>   then https://localhost:4301
ADMIN_BIND=${ADMIN_BIND:-127.0.0.1}
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
  dc ps
  print_signin
}

# ── The four things an install cannot know about itself ──────────────────────
cmd_bootstrap() {
  # shellcheck disable=SC1090
  set -a && . "$ENV_FILE" && set +a
  local email="${FIRST_USER_EMAIL:-}" pass="${FIRST_USER_PASSWORD:-}"

  # Nothing is asked. `write_env` put both in `.env` on the first run; this
  # covers the install that predates that, and appends rather than invents a
  # second account nobody is ever told about.
  if [ -z "$email" ] || [ -z "$pass" ]; then
    email="${email:-$(first_user_email)}"
    pass="${pass:-$(rand_password)}"
    printf '\nFIRST_USER_EMAIL=%s\nFIRST_USER_PASSWORD=%s\n' "$email" "$pass" >> "$ENV_FILE"
    ok "first user written to .env"
  fi

  step "Registering the agency and the first user, and checking the install token"
  # Copied to /app rather than /tmp: node resolves its dependencies by walking up
  # from the script, and from /tmp it never reaches the application's modules.
  dc cp register-install.mjs console:/app/register-install.mjs >/dev/null
  dc exec -T \
    -e AGENCY_NAME="${AGENCY_NAME:-}" \
    -e FIRST_USER_EMAIL="$email" \
    -e FIRST_USER_PASSWORD="$pass" \
    console node /app/register-install.mjs

  # The credential check, in the container that will actually make the call.
  #
  # The console is on `internal` only and cannot reach the internet, so a check
  # run there answered "could not reach" on every healthy install — an alarming
  # message shown to people whose firewall was fine. The gateway is the one
  # container with a route out, and it is the one that polls for mail, so this
  # tests the real path.
  dc cp verify-install.mjs gateway:/app/verify-install.mjs >/dev/null
  dc exec -T gateway node /app/verify-install.mjs
}

# The address staff type. One definition, because a URL assembled twice is a URL
# that disagrees with itself the first time someone changes the port.
console_url() {
  local port_suffix=""
  [ "${CONSOLE_PORT:-443}" = "443" ] || port_suffix=":${CONSOLE_PORT}"
  printf 'https://%s%s' "${SITE_ADDRESS:-localhost}" "$port_suffix"
}

# What the installer's last lines say.
#
# The whole point of an install is that somebody can then sign in, and that
# question used to be answered in three places — an address here, an email the
# operator typed several minutes earlier, a password they chose and did not
# write down. It is one block now, printed last, with everything needed to open
# the product and nothing else.
print_signin() {
  say ""
  printf '%s▸ Sign in%s\n' "$BOLD" "$OFF"
  say ""
  say "  ${BOLD}Console${OFF}   $(console_url)"
  say ""
  say "  Email     ${FIRST_USER_EMAIL:-unknown}"
  say "  Password  ${FIRST_USER_PASSWORD:-see .env}"
  say ""
  say "  ${DIM}Change the password after the first sign-in.${OFF}"
  say "  ${DIM}Both are also in .env — back that file up off this machine.${OFF}"
  say ""
}

cmd_status() {
  # shellcheck disable=SC1090
  set -a && . "$ENV_FILE" && set +a
  dc ps
  say ""
  say "  ${BOLD}Console${OFF}  $(console_url)   ${DIM}the payroll office${OFF}"
  # The address only. A password belongs in the install's last lines and in
  # `.env`, not in the output of a command people paste into a support email.
  say "  ${DIM}sign in as ${FIRST_USER_EMAIL:-see .env} — password in .env (FIRST_USER_PASSWORD)${OFF}"
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
    -v payroll-onprem_console-files:/console:ro \
    -v "$PWD/backups/$stamp:/out" \
    alpine tar czf /out/documents.tar.gz -C / console
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
