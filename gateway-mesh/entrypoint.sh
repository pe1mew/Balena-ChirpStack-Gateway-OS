#!/bin/sh
# Gateway-mesh entrypoint (design.md section 5.5): enable gate, region mapping
# selection, border/relay configuration. Secrets (MESH_ROOT_KEY) are never
# logged.
set -eu

log() { echo "[entrypoint] $*"; }
die() { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

# ---- enable gate (D3) -------------------------------------------------------
if [ "${MESH_ENABLED:-false}" != "true" ]; then
  log "MESH_ENABLED != true — idling"
  exec sleep infinity
fi

# ---- required ---------------------------------------------------------------
[ -n "${MESH_ROOT_KEY:-}" ] || die "MESH_ROOT_KEY is required when MESH_ENABLED=true (AES128 hex, fleet-wide)"
printf '%s' "$MESH_ROOT_KEY" | grep -Eqi '^[0-9a-f]{32}$' || die "MESH_ROOT_KEY must be 32 hex characters"
export MESH_ROOT_KEY

# ---- defaults ---------------------------------------------------------------
export MESH_LOG_LEVEL="${MESH_LOG_LEVEL:-INFO}"
export MESH_BORDER_GATEWAY="${MESH_BORDER_GATEWAY:-false}"
export MESH_IGNORE_DIRECT_UPLINKS="${MESH_IGNORE_DIRECT_UPLINKS:-false}"
export MESH_MAX_HOP_COUNT="${MESH_MAX_HOP_COUNT:-1}"
export MESH_TX_POWER="${MESH_TX_POWER:-16}"
export MESH_DATA_RATE_MODULATION="${MESH_DATA_RATE_MODULATION:-LORA}"
export MESH_DATA_RATE_SF="${MESH_DATA_RATE_SF:-7}"
export MESH_DATA_RATE_BANDWIDTH="${MESH_DATA_RATE_BANDWIDTH:-125000}"
export MESH_DATA_RATE_CODE_RATE="${MESH_DATA_RATE_CODE_RATE:-4/5}"

# ---- region mapping file (default derived from CHANNEL_PLAN) ---------------
CHANNEL_PLAN="${CHANNEL_PLAN:-eu868}"
PLAN=$(echo "$CHANNEL_PLAN" | tr 'A-Z' 'a-z')
case "$PLAN" in
  us915_*|au915_*|cn470_*) PLAN_BASE="${PLAN%_*}" ;;
  *) PLAN_BASE="$PLAN" ;;
esac
REGION=$(echo "${MESH_REGION:-$PLAN_BASE}" | tr 'A-Z' 'a-z')
REGION_FILE="/etc/chirpstack-gateway-mesh/examples/region_${REGION}.toml"
[ -f "$REGION_FILE" ] || die "no mesh region mapping for '$REGION' ($REGION_FILE missing). Available: $(ls /etc/chirpstack-gateway-mesh/examples/ | tr '\n' ' ')"

# ---- frequencies: comma list -> TOML array (region default when unset) ------
# Placeholder MESH_FREQS_TOML: no other env var name is a prefix of it.
if [ -n "${MESH_FREQUENCIES:-}" ]; then
  FREQS="["
  OLDIFS=$IFS; IFS=','
  for f in $MESH_FREQUENCIES; do
    f=$(echo "$f" | tr -d ' ')
    [ -n "$f" ] && FREQS="${FREQS}${f},"
  done
  IFS=$OLDIFS
  export MESH_FREQS_TOML="${FREQS%,}]"
else
  export MESH_FREQS_TOML="[868100000, 868300000, 868500000]"
fi

# ---- optional relay ID override --------------------------------------------
if [ -n "${MESH_RELAY_ID:-}" ]; then
  printf '%s' "$MESH_RELAY_ID" | grep -Eqi '^[0-9a-f]{8}$' || die "MESH_RELAY_ID must be 8 hex characters (4 bytes)"
  export MESH_RELAY_LINE="  relay_id = \"$MESH_RELAY_ID\""
else
  export MESH_RELAY_LINE=""
fi

# ---- start ------------------------------------------------------------------
ROLE=$([ "$MESH_BORDER_GATEWAY" = "true" ] && echo border-gateway || echo relay)
log "role=$ROLE region=$REGION freqs=$MESH_FREQS_TOML tx_power=$MESH_TX_POWER hops=$MESH_MAX_HOP_COUNT"
log "config: templates/chirpstack-gateway-mesh.toml + $(basename "$REGION_FILE")"
exec /usr/bin/chirpstack-gateway-mesh \
  -c /opt/app/templates/chirpstack-gateway-mesh.toml \
  -c "$REGION_FILE"
