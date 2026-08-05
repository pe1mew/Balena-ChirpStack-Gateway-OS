#!/bin/sh
# MQTT-forwarder entrypoint: enable gate + env-var resolution (design.md
# section 5.3), then execs the daemon. Config values are injected through the
# forwarder's native $VAR substitution; every placeholder in
# templates/chirpstack-mqtt-forwarder.toml MUST be exported here.
set -eu

log() { echo "[entrypoint] $*"; }
die() { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

# ---- enable gate (D3) -------------------------------------------------------
if [ "${MQTT_ENABLED:-true}" != "true" ]; then
  log "MQTT_ENABLED != true — idling"
  exec sleep infinity
fi

# ---- defaults (section 5.3) -------------------------------------------------
[ -n "${MQTT_SERVER:-}" ] || die "MQTT_SERVER is required (e.g. ssl://your-broker:8883)"
export MQTT_SERVER
export CHANNEL_PLAN="${CHANNEL_PLAN:-eu868}"
export MQTT_TOPIC_PREFIX="${MQTT_TOPIC_PREFIX:-$(echo "$CHANNEL_PLAN" | tr 'A-Z' 'a-z')}"
export MQTT_LOG_LEVEL="${MQTT_LOG_LEVEL:-info}"
export MQTT_USERNAME="${MQTT_USERNAME:-}"
export MQTT_PASSWORD="${MQTT_PASSWORD:-}"
export MQTT_QOS="${MQTT_QOS:-0}"
export MQTT_JSON="${MQTT_JSON:-false}"
export MQTT_FILTER_LORAWAN_ONLY="${MQTT_FILTER_LORAWAN_ONLY:-true}"

# ---- TLS: PEM content in variables -> files ---------------------------------
# Placeholder names (MQTT_CA_FILE etc.) deliberately do NOT extend the names
# of the PEM-content variables: the daemon substitutes every $VAR in
# unspecified order, so no placeholder may have another env var's name as its
# prefix ($MQTT_CA_CERT would corrupt $MQTT_CA_CERT_FILE).
CERT_DIR=/var/run/mqtt-forwarder
mkdir -p "$CERT_DIR"
export MQTT_CA_FILE=""
export MQTT_CERT_FILE=""
export MQTT_KEY_FILE=""
if [ -n "${MQTT_CA_CERT:-}" ]; then
  printf '%s\n' "$MQTT_CA_CERT" > "$CERT_DIR/ca.pem"
  MQTT_CA_FILE="$CERT_DIR/ca.pem"
fi
if [ -n "${MQTT_TLS_CERT:-}" ]; then
  printf '%s\n' "$MQTT_TLS_CERT" > "$CERT_DIR/cert.pem"
  MQTT_CERT_FILE="$CERT_DIR/cert.pem"
fi
if [ -n "${MQTT_TLS_KEY:-}" ]; then
  printf '%s\n' "$MQTT_TLS_KEY" > "$CERT_DIR/key.pem"
  chmod 600 "$CERT_DIR/key.pem"
  MQTT_KEY_FILE="$CERT_DIR/key.pem"
fi

# ---- filters: comma lists -> TOML arrays ------------------------------------
to_toml_array() {
  out="["
  OLDIFS=$IFS; IFS=','
  for item in $1; do
    item=$(echo "$item" | tr -d ' ')
    [ -n "$item" ] && out="${out}\"${item}\","
  done
  IFS=$OLDIFS
  echo "${out%,}]"
}
export MQTT_DEV_ADDR_FILTER_TOML=$(to_toml_array "${MQTT_FILTER_DEV_ADDR_PREFIXES:-}")
export MQTT_JOIN_EUI_FILTER_TOML=$(to_toml_array "${MQTT_FILTER_JOIN_EUI_PREFIXES:-}")

# ---- backend: concentratord direct, or the gateway-mesh proxy API -----------
# On the mesh backend, wait until the mesh proxy accepts connections before
# starting (zero-ID race mitigation: the forwarder reads the gateway ID only
# once; combined with the mesh's own concentratord gate this guarantees the
# proxy knows the real ID by the time we ask).
wait_for() {
  n=0
  until nc -z -w 2 "$1" "$2" 2>/dev/null; do
    n=$((n+1)); [ $((n % 15)) -eq 1 ] && log "waiting for $3 ($1:$2) ..."
    sleep 2
  done
  sleep 3
  log "$3 reachable"
}
case "${MQTT_BACKEND:-concentratord}" in
  concentratord)
    export MQTT_EVENT_URL="tcp://concentratord:3001"
    export MQTT_COMMAND_URL="tcp://concentratord:3002"
    ;;
  mesh)
    wait_for gateway-mesh 3012 "gateway-mesh proxy API"
    export MQTT_EVENT_URL="tcp://gateway-mesh:3011"
    export MQTT_COMMAND_URL="tcp://gateway-mesh:3012"
    ;;
  *) die "MQTT_BACKEND must be 'concentratord' or 'mesh'" ;;
esac

# ---- start ------------------------------------------------------------------
log "server=$MQTT_SERVER topic_prefix=$MQTT_TOPIC_PREFIX qos=$MQTT_QOS json=$MQTT_JSON backend=${MQTT_BACKEND:-concentratord}"
log "tls: ca=${MQTT_CA_FILE:-none} cert=${MQTT_CERT_FILE:-none} key=$([ -n "$MQTT_KEY_FILE" ] && echo set || echo none)"
exec /usr/bin/chirpstack-mqtt-forwarder \
  -c /opt/app/templates/chirpstack-mqtt-forwarder.toml
