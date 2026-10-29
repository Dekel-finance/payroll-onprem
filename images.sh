# images.sh — getting the release images onto this machine. Sourced, not run.
#
# Used by operator.sh and update.sh (POSIX sh, inside the operator container:
# busybox wget, no curl) and by install.sh (bash, on the host: curl). Plain
# POSIX sh for that reason. install.sh sources it under `set -eu -o pipefail`,
# so every pipeline that may legitimately find nothing ends in `|| true`.
#
# The registry address is not written in any file of this kit. It is asked
# from the broker with this install's token on each pull, kept in a shell
# variable, and the images are retagged under local names
# (payroll.invalid/...) so `docker images` and `docker inspect` do not show it
# either. `.invalid` is a reserved domain: a pull of these names can never go
# to Docker Hub or anywhere else.
#
# Callers must set before use:
#   KIT_ENV     path to this install's .env
# Optional:
#   BROKER_URL  overrides the .env value and the default

LOCAL_PREFIX="payroll.invalid"
APP_REPO="payroll-onprem"
CONNECTOR_REPO="payroll-michpal-worker"
VERSION_LABEL="org.opencontainers.image.version"

# A value from .env, or empty. Same rule as install.sh's env_value.
kit_env() {
  [ -f "${KIT_ENV:-}" ] || return 0
  sed -n "s/^$1=//p" "$KIT_ENV" | head -1
}

# The channel this install follows: BUNDLE_VERSION in .env, default stable.
kit_channel() {
  c="$(kit_env BUNDLE_VERSION)"
  printf '%s' "${c:-stable}"
}

# GET to stdout, with this install's token and id when they are set (the
# broker's x-broker-install header, as the gateway sends it). curl on the
# host, busybox wget in the operator.
http_get() {
  url="$1"; tok="$2"; iid="$3"
  if command -v curl >/dev/null 2>&1; then
    set -- -fsS -m 20
    [ -n "$tok" ] && set -- "$@" -H "Authorization: Bearer $tok"
    [ -n "$iid" ] && set -- "$@" -H "x-broker-install: $iid"
    curl "$@" "$url"
  else
    set -- -q -T 20 -O -
    [ -n "$tok" ] && set -- "$@" --header "Authorization: Bearer $tok"
    [ -n "$iid" ] && set -- "$@" --header "x-broker-install: $iid"
    wget "$@" "$url"
  fi
}

# Ask the broker which version the channel serves and where to pull it.
# Sets RELEASE_REGISTRY and RELEASE_VERSION. Prints nothing on success.
release_lookup() {
  channel="$1"
  # Before .env exists (install.sh check), the values we sent may be exported.
  # A missing token is not a reason to skip: the broker decides (it still
  # answers while its open fallback is on).
  token="$(kit_env BROKER_TOKEN)"
  token="${token:-${INSTALL_TOKEN:-}}"
  install_id="$(kit_env METRICS_INSTALL_ID)"
  install_id="${install_id:-${INSTALL_ID:-}}"
  base="${BROKER_URL:-$(kit_env BROKER_URL)}"
  base="${base:-https://broker.dekel.io}"
  base="${base%/}"
  answer="$(http_get "$base/v1/release?channel=$channel&format=env" "$token" "$install_id" 2>/dev/null)" || {
    echo "the broker did not answer the release check (token refused, or no network)" >&2
    return 1
  }
  RELEASE_REGISTRY="$(printf '%s\n' "$answer" | sed -n 's/^registry=//p' | head -1)"
  RELEASE_VERSION="$(printf '%s\n' "$answer" | sed -n 's/^version=//p' | head -1)"
  if [ -z "$RELEASE_REGISTRY" ] || [ -z "$RELEASE_VERSION" ]; then
    echo "the broker's release answer was incomplete" >&2
    return 1
  fi
  return 0
}

# Local name of an image: payroll.invalid/<repo>:<channel>
local_image() { printf '%s/%s:%s' "$LOCAL_PREFIX" "$1" "$2"; }

# The version label of a local image, or empty.
image_version() {
  docker image inspect -f "{{index .Config.Labels \"$VERSION_LABEL\"}}" "$1" 2>/dev/null || true
}

# This install's containers, by id: running ones, or all with `-a`. Asked
# from compose, not filtered by project name: an install may set its own
# COMPOSE_PROJECT_NAME in .env (the demo box runs `demo` and `internal`).
# Runs in the kit directory, like every caller.
kit_containers() {
  docker compose -f docker-compose.yml ps -q "$@" 2>/dev/null || true
}

# The versions the running app containers carry, one per line, de-duplicated.
# Empty when nothing is running. Selected by the image's title label, not by
# image name: once a pull moves the local tag, a container not yet recreated
# shows only an image ID. The connector has its own title and is not counted
# (stale_services covers it).
running_versions() {
  for id in $(kit_containers); do
    title="$(docker inspect -f "{{index .Config.Labels \"org.opencontainers.image.title\"}}" "$id" 2>/dev/null || true)"
    [ "$title" = "payroll on-prem bundle" ] || continue
    docker inspect -f "{{index .Config.Labels \"$VERSION_LABEL\"}}" "$id" 2>/dev/null || true
  done | sort -u || true
}

# Services whose container runs an older image than its local tag: left
# behind by the busy guard, or by an apply that was cut short. Compared by
# image id, so it works for images without a version label too.
stale_services() {
  app_id="$(docker image inspect -f '{{.Id}}' "$(local_image "$APP_REPO" "$1")" 2>/dev/null || true)"
  con_id="$(docker image inspect -f '{{.Id}}' "$(local_image "$CONNECTOR_REPO" "$1")" 2>/dev/null || true)"
  for id in $(kit_containers); do
    printf '%s %s\n' "$id" "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$id" 2>/dev/null || true)"
  done \
    | while read -r id svc; do
        case "$svc" in
          michpal-worker) want="$con_id" ;;
          *)
            title="$(docker inspect -f "{{index .Config.Labels \"org.opencontainers.image.title\"}}" "$id" 2>/dev/null || true)"
            [ "$title" = "payroll on-prem bundle" ] || continue
            want="$app_id"
            ;;
        esac
        have="$(docker inspect -f '{{.Image}}' "$id" 2>/dev/null || true)"
        if [ -n "$want" ] && [ "$have" != "$want" ]; then printf '%s\n' "$svc"; fi
      done | sort -u || true
}

# The agent, the connector and the console report a run in flight on their
# health route ({busy: true}); restarting one then loses the run (the agent's
# reply, the connector's payroll session, the console's import walk). Same
# check as the cloud worker's guard. Run inside the container, so no port is
# opened for it. A service that is not running or does not answer is not busy.
busy_probe() {
  printf "fetch('%s').then(r=>r.json()).then(j=>{if(j.busy)console.log('busy: '+(j.activeJob||''))}).catch(()=>{})" "$1"
}
busy_services() {
  for pair in agent=http://127.0.0.1:8080/health michpal-worker=http://127.0.0.1:8080/health console=http://127.0.0.1:3201/api/health; do
    svc="${pair%%=*}"
    out="$(docker compose -f docker-compose.yml exec -T "$svc" node -e "$(busy_probe "${pair#*=}")" 2>/dev/null || true)"
    case "$out" in busy*) printf '%s\n' "$svc" ;; esac
  done
}

# The services `compose up` may touch now: all of them except the operator
# (it must never recreate itself mid-apply, see update.sh) and any busy one.
# Prints one line per busy service skipped to stderr.
apply_services() {
  busy="$(busy_services)"
  for b in $busy; do echo "$b is busy — left on its current version until the next cycle" >&2; done
  docker compose -f docker-compose.yml config --services 2>/dev/null | while read -r svc; do
    [ "$svc" = operator ] && continue
    case " $(printf '%s ' $busy)" in *" $svc "*) continue ;; esac
    printf '%s ' "$svc"
  done || true
}

# Remove every reference to an image except its payroll.invalid tags: the
# registry tag and the registry digest reference a pull leaves behind.
drop_remote_refs() {
  refs="$(docker image inspect -f '{{range .RepoTags}}{{.}} {{end}}{{range .RepoDigests}}{{.}} {{end}}' "$1" 2>/dev/null || true)"
  for ref in $refs; do
    case "$ref" in
      "$LOCAL_PREFIX"/*) ;;
      *) docker rmi "$ref" >/dev/null 2>&1 || true ;;
    esac
  done
}

# Pull <repo>:<channel> from RELEASE_REGISTRY and keep it only under its local
# name. The pull's own output is discarded: it names the registry, and the
# operator's output ends up in container logs and support bundles.
fetch_image() {
  repo="$1"; channel="$2"
  remote="$RELEASE_REGISTRY/$repo:$channel"
  target="$(local_image "$repo" "$channel")"
  docker pull -q "$remote" >/dev/null 2>&1 || { echo "pull of $repo:$channel failed" >&2; return 1; }
  # One retry: two installs on one machine (the demo box runs `demo` and
  # `internal`) share these local names, and when both cycles tag in the same
  # second the second one fails with "already exists" (2026-10-20).
  docker tag "$remote" "$target" 2>/dev/null || { sleep 2; docker tag "$remote" "$target"; } || return 1
  drop_remote_refs "$target"
  return 0
}

# An install from before images.sh has the images only under their registry
# names. Give them the local name so compose (pull_policy: never) can start
# without a pull. Matches by repository, so the host is not named here.
adopt_legacy_images() {
  channel="$1"
  for repo in "$APP_REPO" "$CONNECTOR_REPO"; do
    target="$(local_image "$repo" "$channel")"
    docker image inspect "$target" >/dev/null 2>&1 && continue
    legacy="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
      | grep -E "/$repo:$channel\$" | grep -v "^$LOCAL_PREFIX/" | head -1 || true)"
    [ -n "$legacy" ] && docker tag "$legacy" "$target" >/dev/null 2>&1 || true
  done
  return 0
}

# After the containers are on the local names: untag every registry-named copy
# of our two images and delete old payroll images nothing uses any more.
remove_legacy_images() {
  docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | grep -E "/($APP_REPO|$CONNECTOR_REPO):" | grep -v "^$LOCAL_PREFIX/" \
    | while read -r ref; do docker rmi "$ref" >/dev/null 2>&1 || true; done || true
  # Digest-only references (tag <none>) left by earlier pulls.
  docker images --digests --format '{{.Repository}}@{{.Digest}}' 2>/dev/null \
    | grep -E "/($APP_REPO|$CONNECTOR_REPO)@sha256:" | grep -v "^$LOCAL_PREFIX/" \
    | while read -r ref; do docker rmi "$ref" >/dev/null 2>&1 || true; done || true
  # Images replaced by an update are left untagged; remove those nothing runs.
  docker image prune -f --filter "label=org.opencontainers.image.title=payroll on-prem bundle" >/dev/null 2>&1 || true
  docker image prune -f --filter "label=org.opencontainers.image.title=payroll michpal connector" >/dev/null 2>&1 || true
  return 0
}

# docker-compose.yml runs mongo:${MONGO_VERSION:-8}. An install already running
# another Mongo (e.g. 4.4 on a CPU without AVX) whose .env has no MONGO_VERSION
# would be switched to 8, and the database would not start. So when the key is
# missing, write the version of the Mongo container that exists. Never changes
# a value that is set.
pin_mongo_version() {
  [ -f "${KIT_ENV:-}" ] || return 0
  grep -q '^MONGO_VERSION=' "$KIT_ENV" && return 0
  img=""
  for id in $(kit_containers -a mongo); do
    img="$(docker inspect -f '{{.Config.Image}}' "$id" 2>/dev/null || true)"
    break
  done
  case "$img" in
    mongo:?*)
      [ -z "$(tail -c1 "$KIT_ENV")" ] || echo >> "$KIT_ENV"
      printf 'MONGO_VERSION=%s\n' "${img#mongo:}" >> "$KIT_ENV"
      echo "pinned MONGO_VERSION=${img#mongo:} in .env (the database that is running)"
      ;;
  esac
  return 0
}

# ── .env keys this version of the bundle needs ───────────────────────────────
#
# One copy, run by update.sh (the operator's path and `./install.sh update`)
# and by `./install.sh install`. Appended only when missing; an existing value
# is NEVER touched — two of these seal data at rest, and regenerating one
# turns what it sealed into noise. Call from the kit directory.
rand_hex() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
rand_b64url() { head -c "$1" /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n'; }

# Append KEY=VALUE when KEY is not in .env at all.
kit_env_ensure() {
  grep -q "^$1=" "$KIT_ENV" 2>/dev/null && return 0
  [ -z "$(tail -c1 "$KIT_ENV" 2>/dev/null)" ] || echo >> "$KIT_ENV"
  printf '%s=%s\n' "$1" "$2" >> "$KIT_ENV"
  echo "added $1 to .env"
}

# Set KEY when it is missing or blank. Never overwrites a value that is there:
# an install's credentials are not ours to replace on an update. Rewritten in
# place (cat >), so the file keeps its owner and mode (install.sh makes it 600).
kit_env_fill() {
  [ -n "$2" ] || return 0
  [ -z "$(kit_env "$1")" ] || return 0
  if grep -q "^$1=" "$KIT_ENV" 2>/dev/null; then
    sed "s|^$1=.*|$1=$2|" "$KIT_ENV" > "$KIT_ENV.tmp" && cat "$KIT_ENV.tmp" > "$KIT_ENV" && rm -f "$KIT_ENV.tmp"
  else
    [ -z "$(tail -c1 "$KIT_ENV" 2>/dev/null)" ] || echo >> "$KIT_ENV"
    printf '%s=%s\n' "$1" "$2" >> "$KIT_ENV"
  fi
  echo "filled $1 in .env"
}

migrate_env() {
  [ -f "${KIT_ENV:-}" ] || return 0
  # The connector's bearer (default-on since 1.1.19).
  kit_env_ensure WORKER_TOKEN "$(rand_hex)"
  # The stored-credential keyring: seals the RDP password the office types into
  # settings. Installs from before it shipped have no key and cannot save.
  kit_env_ensure SECRET_KEYS "v1:$(rand_b64url 32)"
  kit_env_ensure SECRET_ACTIVE_KEY "v1"
  # Where this kit lives on the host — the operator mounts it at the same path,
  # which is what lets compose-in-a-container resolve ./Caddyfile and .env.
  kit_env_ensure KIT_DIR "$(pwd)"
  pin_mongo_version

  # The install credential. BROKER_TOKEN and METRICS_INSTALL_TOKEN are the SAME
  # token (`dki_…`), the one we issue with the install. An install with only one
  # of them comes up healthy, but without BROKER_TOKEN its AI calls and update
  # checks carry no token (the demo box's `internal`, 2026-10-20). So the
  # other is filled from whichever is set. Never generated: a random value would
  # turn a refusal that names its cause into an authentication failure.
  broker="$(kit_env BROKER_TOKEN)"
  metrics="$(kit_env METRICS_INSTALL_TOKEN)"
  [ -n "$broker" ] && kit_env_fill METRICS_INSTALL_TOKEN "$broker"
  [ -n "$metrics" ] && kit_env_fill BROKER_TOKEN "$metrics"
  if [ -n "${INSTALL_TOKEN:-}" ]; then
    kit_env_fill BROKER_TOKEN "$INSTALL_TOKEN"
    kit_env_fill METRICS_INSTALL_TOKEN "$INSTALL_TOKEN"
  fi
  return 0
}
