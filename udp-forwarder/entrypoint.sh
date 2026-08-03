#!/bin/sh
# UDP-forwarder entrypoint (design.md section 5.4): enable gate + resin-style
# indexed SERVER_n variables -> [[udp_forwarder.servers]] TOML blocks.
set -eu

log() { echo "[entrypoint] $*"; }
die() { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

# ---- enable gate (D3) -------------------------------------------------------
if [ "${UDP_ENABLED:-false}" != "true" ]; then
  log "UDP_ENABLED != true — idling"
  exec sleep infinity
fi

# ---- defaults ---------------------------------------------------------------
export UDP_LOG_LEVEL="${UDP_LOG_LEVEL:-INFO}"
export UDP_METRICS_BIND="${UDP_METRICS_BIND:-}"
FILTER_LORAWAN_ONLY="${UDP_FILTER_LORAWAN_ONLY:-true}"

# ---- indexed server slots n=0..3 -> TOML blocks -----------------------------
# Placeholder is UDP_UPSTREAMS_TOML: no other env var name is a prefix of it
# (the daemon substitutes every $VAR in unspecified order).
BLOCKS=""
COUNT=0
nl='
'
for n in 0 1 2 3; do
  eval "addr=\${UDP_SERVER_ADDRESS_${n}:-}"
  eval "port=\${UDP_SERVER_PORT_${n}:-1700}"
  eval "enabled=\${UDP_SERVER_ENABLED_${n}:-true}"
  [ -n "$addr" ] || continue
  if [ "$enabled" != "true" ]; then
    log "server slot $n ($addr:$port) disabled"
    continue
  fi
  BLOCKS="$BLOCKS${nl}  [[udp_forwarder.servers]]${nl}    server = \"$addr:$port\"${nl}    [udp_forwarder.servers.filters]${nl}      lorawan_only = $FILTER_LORAWAN_ONLY"
  COUNT=$((COUNT + 1))
  log "server slot $n: $addr:$port"
done
[ "$COUNT" -gt 0 ] || die "UDP_ENABLED=true but no enabled server slots — set UDP_SERVER_ADDRESS_0 (and optionally _PORT_0/_ENABLED_0)"
export UDP_UPSTREAMS_TOML="$BLOCKS"

# ---- start ------------------------------------------------------------------
log "$COUNT upstream server(s), metrics_bind=${UDP_METRICS_BIND:-disabled}"
exec /usr/bin/chirpstack-udp-forwarder \
  -c /opt/app/templates/chirpstack-udp-forwarder.toml
