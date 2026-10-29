#!/bin/sh
# otel-collector-check.sh — which attribute keys the otel-collector would send.
#
# Runs the collector once for 75s with the debug exporter in place of Better
# Stack (same config, mounts and networks as the real service), lists every
# attribute key in its output, and fails on any key outside the allowlist.
# Run after every collector version bump.
#
#   cd <install dir> && sh otel-collector-check.sh
set -eu
cd "$(dirname "$0")"

ALLOWED="service.name host.name install.id deployment.environment container.name container.image.name cpu state device mountpoint type direction interface"

out="$(timeout 75 docker compose run --rm --no-deps -e OTEL_SEND=yes otel-collector \
  --config=/etc/otelcol-contrib/config.yaml \
  --config="yaml:exporters::debug::verbosity: detailed" \
  --config="yaml:service::pipelines::metrics::exporters: [debug]" 2>&1 || true)"

keys="$(printf '%s\n' "$out" | sed -n -E 's/^[[:space:]]+-> ([a-z][a-z0-9._]*): .*/\1/p' | sort -u)"
[ -n "$keys" ] || { echo "otel-collector-check: no metrics seen in 75s"; printf '%s\n' "$out" | tail -20; exit 1; }

bad=0
for k in $keys; do
  case " $ALLOWED " in
    *" $k "*) echo "  ok   $k" ;;
    *) echo "  NOT ALLOWED  $k"; bad=1 ;;
  esac
done
[ "$bad" = 0 ] && echo "otel-collector-check: passed" || { echo "otel-collector-check: FAILED"; exit 1; }
