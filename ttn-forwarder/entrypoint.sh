#!/bin/sh
# TTN-forwarder entrypoint: enable gate + env-var resolution (design.md
# section 5.3 conventions), then execs the daemon. Config values are injected
# through the forwarder's native $VAR substitution; every placeholder in
# templates/chirpstack-ttn-mqtt-forwarder.toml MUST be exported here.
set -eu

log() { echo "[entrypoint] $*"; }
die() { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

# ---- enable gate (D3) -------------------------------------------------------
if [ "${TTN_ENABLED:-false}" != "true" ]; then
  log "TTN_ENABLED != true — idling"
  exec sleep infinity
fi

# ---- defaults (global) ------------------------------------------------------
export TTN_LOG_LEVEL="${TTN_LOG_LEVEL:-info}"
export TTN_CRC_OK="${TTN_CRC_OK:-true}"
export TTN_CRC_INVALID="${TTN_CRC_INVALID:-false}"
export TTN_CRC_MISSING="${TTN_CRC_MISSING:-false}"
# Like-for-like mp_pkt_fwd replacement: forward non-LoRaWAN frames too.
export TTN_FILTER_LORAWAN_ONLY="${TTN_FILTER_LORAWAN_ONLY:-false}"
export TTN_DESCRIPTION="${TTN_DESCRIPTION:-}"
export TTN_PLATFORM="${TTN_PLATFORM:-Balena-ChirpStack-Gateway-OS}"
export TTN_CONTACT_EMAIL="${TTN_CONTACT_EMAIL:-}"
export TTN_LATITUDE="${TTN_LATITUDE:-0.0}"
export TTN_LONGITUDE="${TTN_LONGITUDE:-0.0}"
export TTN_ALTITUDE="${TTN_ALTITUDE:-0}"
# Per-connection defaults, overridable per slot with the _n suffix.
KEEP_ALIVE_DEFAULT="${TTN_KEEP_ALIVE:-20s}"
RECONNECT_MAX_DEFAULT="${TTN_RECONNECT_MAX:-5m}"
QUEUE_SIZE_DEFAULT="${TTN_QUEUE_SIZE:-100}"
EVENT_MAX_AGE_DEFAULT="${TTN_EVENT_MAX_AGE:-5m}"

# ---- frequency plan: explicit override, else derived from CHANNEL_PLAN -----
if [ -z "${TTN_FREQUENCY_PLAN:-}" ]; then
  case "$(echo "${CHANNEL_PLAN:-eu868}" | tr 'A-Z' 'a-z')" in
    eu868) TTN_FREQUENCY_PLAN="EU_863_870" ;;
    us915*) TTN_FREQUENCY_PLAN="US_902_928" ;;
    au915*) TTN_FREQUENCY_PLAN="AU_915_928" ;;
    as923*) TTN_FREQUENCY_PLAN="AS_923" ;;
    in865|in868) TTN_FREQUENCY_PLAN="IN_865_867" ;;
    ru864) TTN_FREQUENCY_PLAN="RU_864_870" ;;
    kr920) TTN_FREQUENCY_PLAN="KR_920_923" ;;
    cn470*) TTN_FREQUENCY_PLAN="CN_470_510" ;;
    *) TTN_FREQUENCY_PLAN="" ;;
  esac
fi
export TTN_FREQUENCY_PLAN

# ---- connection slots n=0..3 -> double-bracket ttn TOML blocks --------------
# Unsuffixed TTN_GATEWAY_ID / TTN_GATEWAY_KEY / TTN_SERVER / TTN_TLS_ENABLED /
# TTN_DOWNLINK_ENABLED / TTN_CA_CERT / TTN_NAME act as aliases for slot 0
# (back-compat with single-connection deployments). Gateway keys are embedded
# in the rendered config only — never logged.
CERT_DIR=/var/run/ttn-forwarder
mkdir -p "$CERT_DIR"
BLOCKS=""
COUNT=0
nl='
'
for n in 0 1 2 3; do
  eval "gw_id=\${TTN_GATEWAY_ID_${n}:-}"
  eval "gw_key=\${TTN_GATEWAY_KEY_${n}:-}"
  eval "server=\${TTN_SERVER_${n}:-}"
  eval "enabled=\${TTN_CONNECTION_ENABLED_${n}:-true}"
  eval "name=\${TTN_NAME_${n}:-conn${n}}"
  eval "downlink=\${TTN_DOWNLINK_ENABLED_${n}:-}"
  eval "tls=\${TTN_TLS_ENABLED_${n}:-}"
  eval "ca_pem=\${TTN_CA_CERT_${n}:-}"
  eval "keep_alive=\${TTN_KEEP_ALIVE_${n}:-$KEEP_ALIVE_DEFAULT}"
  eval "reconnect=\${TTN_RECONNECT_MAX_${n}:-$RECONNECT_MAX_DEFAULT}"
  eval "queue_size=\${TTN_QUEUE_SIZE_${n}:-$QUEUE_SIZE_DEFAULT}"
  eval "event_max_age=\${TTN_EVENT_MAX_AGE_${n}:-$EVENT_MAX_AGE_DEFAULT}"
  if [ "$n" = "0" ]; then
    # unsuffixed aliases fill slot 0 when the suffixed variables are unset
    gw_id="${gw_id:-${TTN_GATEWAY_ID:-}}"
    gw_key="${gw_key:-${TTN_GATEWAY_KEY:-}}"
    server="${server:-${TTN_SERVER:-}}"
    name="${TTN_NAME_0:-${TTN_NAME:-conn0}}"
    downlink="${downlink:-${TTN_DOWNLINK_ENABLED:-}}"
    tls="${tls:-${TTN_TLS_ENABLED:-}}"
    ca_pem="${ca_pem:-${TTN_CA_CERT:-}}"
  fi
  [ -n "$gw_id" ] || continue
  if [ "$enabled" != "true" ]; then
    log "connection slot $n ($name) disabled"
    continue
  fi
  [ -n "$gw_key" ] || die "connection slot $n ($gw_id): gateway key missing (TTN_GATEWAY_KEY_${n})"
  server="${server:-eu1.cloud.thethings.network:1881}"
  downlink="${downlink:-true}"
  tls="${tls:-false}"
  ca_file=""
  if [ "$tls" = "true" ]; then
    if [ -n "$ca_pem" ]; then
      printf '%s\n' "$ca_pem" > "$CERT_DIR/ca_${n}.pem"
      ca_file="$CERT_DIR/ca_${n}.pem"
    else
      # The Things Stack uses a publicly trusted CA; the system bundle works.
      ca_file="/etc/ssl/certs/ca-certificates.crt"
    fi
  fi
  BLOCKS="$BLOCKS${nl}[[ttn]]${nl}  name = \"$name\"${nl}  server = \"$server\"${nl}  gateway_id = \"$gw_id\"${nl}  gateway_key = \"$gw_key\"${nl}  downlink_enabled = $downlink${nl}  keep_alive_interval = \"$keep_alive\"${nl}  reconnect_interval_max = \"$reconnect\"${nl}  queue_size = $queue_size${nl}  event_max_age = \"$event_max_age\"${nl}  tls_enabled = $tls${nl}  ca_cert = \"$ca_file\""
  COUNT=$((COUNT + 1))
  log "connection slot $n: name=$name server=$server gateway_id=$gw_id downlink=$downlink tls=$tls"
done
[ "$COUNT" -gt 0 ] || die "TTN_ENABLED=true but no connection slots — set TTN_GATEWAY_ID (slot 0 alias) or TTN_GATEWAY_ID_0..3 with matching keys"
export TTN_CONNECTIONS_TOML="$BLOCKS"

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
export TTN_DEV_ADDR_FILTER_TOML=$(to_toml_array "${TTN_FILTER_DEV_ADDR_PREFIXES:-}")
export TTN_JOIN_EUI_FILTER_TOML=$(to_toml_array "${TTN_FILTER_JOIN_EUI_PREFIXES:-}")

# ---- backend: concentratord direct, or the gateway-mesh proxy API -----------
# Mesh backend: wait for the proxy before starting (zero-ID race mitigation,
# same rationale as in the mqtt-forwarder entrypoint).
wait_for() {
  n=0
  until nc -z -w 2 "$1" "$2" 2>/dev/null; do
    n=$((n+1)); [ $((n % 15)) -eq 1 ] && log "waiting for $3 ($1:$2) ..."
    sleep 2
  done
  sleep 3
  log "$3 reachable"
}
case "${TTN_BACKEND:-concentratord}" in
  concentratord)
    export TTN_EVENT_URL="tcp://concentratord:3001"
    export TTN_COMMAND_URL="tcp://concentratord:3002"
    ;;
  mesh)
    wait_for gateway-mesh 3012 "gateway-mesh proxy API"
    export TTN_EVENT_URL="tcp://gateway-mesh:3011"
    export TTN_COMMAND_URL="tcp://gateway-mesh:3012"
    ;;
  *) die "TTN_BACKEND must be 'concentratord' or 'mesh'" ;;
esac

# ---- start ------------------------------------------------------------------
log "$COUNT TTN connection(s), backend=${TTN_BACKEND:-concentratord}, frequency_plan=${TTN_FREQUENCY_PLAN:-unset}"
exec /usr/bin/chirpstack-ttn-mqtt-forwarder \
  -c /opt/app/templates/chirpstack-ttn-mqtt-forwarder.toml
