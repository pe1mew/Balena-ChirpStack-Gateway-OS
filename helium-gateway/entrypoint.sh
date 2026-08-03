#!/bin/sh
# Helium gateway-rs entrypoint (design.md section 5.6 / D7): enable gate +
# identity resolution with fixed priority:
#   1. ECC608 secure element (supervised trial start — gateway-rs v1.3.0 has
#      no offline keypair probe; the keypair loads at server startup, so a
#      short-lived server means no/absent ECC and we fall back)
#   2. supplied swarm key (HELIUM_SWARM_KEY, base64) — overwrites every start
#   3. generated keypair, persisted in the helium-data volume
# All other settings pass through natively as GW_* env vars.
# HELIUM_SWARM_KEY is a secret: never logged.
set -eu

log() { echo "[entrypoint] $*"; }
die() { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

# ---- enable gate (D3) -------------------------------------------------------
if [ "${HELIUM_ENABLED:-false}" != "true" ]; then
  log "HELIUM_ENABLED != true — idling"
  exec sleep infinity
fi

DATA_DIR=/data/helium
mkdir -p "$DATA_DIR"
GW=/usr/bin/helium_gateway
CFG=/opt/app/settings.toml

# ---- defaults ---------------------------------------------------------------
# GWMP listener must bind the container network (upstream default is loopback).
export GW_LISTEN="${GW_LISTEN:-0.0.0.0:1680}"
# Helium region from CHANNEL_PLAN unless explicitly set.
if [ -z "${GW_REGION:-}" ]; then
  PLAN=$(echo "${CHANNEL_PLAN:-eu868}" | tr 'A-Z' 'a-z')
  case "$PLAN" in
    us915_*|au915_*|cn470_*) PLAN="${PLAN%_*}" ;;
  esac
  export GW_REGION=$(echo "$PLAN" | tr 'a-z' 'A-Z')
fi

ECC_MODE="${HELIUM_ECC:-auto}"
ECC_URI="${HELIUM_ECC_URI:-ecc://i2c-1:96?slot=0}"
ONBOARDING_URI="${HELIUM_ONBOARDING_URI:-ecc://i2c-1:96?slot=15}"

# ---- server management (PID 1 duties) ---------------------------------------
CHILD=""
trap '[ -n "$CHILD" ] && kill -TERM "$CHILD" 2>/dev/null' TERM INT

start_server() {
  "$GW" -c "$CFG" server &
  CHILD=$!
}

log_pubkey_async() {
  ( sleep 6
    KEYS=$("$GW" -c "$CFG" key info 2>/dev/null | tr -d ' \n' || true)
    [ -n "$KEYS" ] && echo "[entrypoint] key info: $KEYS"
  ) &
}

use_file_identity() {
  if [ -n "${HELIUM_SWARM_KEY:-}" ]; then
    printf '%s' "$HELIUM_SWARM_KEY" | base64 -d > "$DATA_DIR/keypair.bin" 2>/dev/null \
      || die "HELIUM_SWARM_KEY is not valid base64"
    chmod 600 "$DATA_DIR/keypair.bin"
    export GW_KEYPAIR="$DATA_DIR/keypair.bin"
    log "identity: supplied swarm key (written to $GW_KEYPAIR)"
  else
    export GW_KEYPAIR="${GW_KEYPAIR:-$DATA_DIR/keypair.bin}"
    log "identity: file keypair at $GW_KEYPAIR (generated on first start; back it up after onboarding)"
  fi
  unset GW_ONBOARDING || true
}

# ---- identity resolution (D7 priority) --------------------------------------
log "region=$GW_REGION listen=$GW_LISTEN ecc=$ECC_MODE"

case "$ECC_MODE" in
  true|auto)
    if [ "$ECC_MODE" = "auto" ] && [ ! -e /dev/i2c-1 ]; then
      log "no /dev/i2c-1 — skipping ECC608"
      use_file_identity
      start_server
    else
      export GW_KEYPAIR="$ECC_URI"
      export GW_ONBOARDING="$ONBOARDING_URI"
      log "identity: trying ECC608 secure element ($ECC_URI)"
      start_server
      sleep 8
      if kill -0 "$CHILD" 2>/dev/null; then
        log "identity: ECC608 confirmed — original onboarded identity in use"
      elif [ "$ECC_MODE" = "true" ]; then
        wait "$CHILD" || true
        die "HELIUM_ECC=true but gateway-rs could not start with $ECC_URI"
      else
        wait "$CHILD" 2>/dev/null || true
        log "identity: ECC608 not usable — falling back (set HELIUM_ECC=false to skip this probe)"
        use_file_identity
        start_server
      fi
    fi
    ;;
  false)
    use_file_identity
    start_server
    ;;
  *) die "HELIUM_ECC must be auto, true or false" ;;
esac

log_pubkey_async
log "wire the UDP forwarder to this service: UDP_SERVER_ADDRESS_n=helium-gateway, UDP_SERVER_PORT_n=1680"
wait "$CHILD"
exit $?
