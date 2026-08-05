#!/bin/sh
# Concentratord entrypoint: resolves env vars (design.md section 5.2),
# selects the chipset binary and region/channel files, then execs the daemon.
# Config values are injected through concentratord's native $VAR substitution;
# every placeholder in templates/concentratord.toml MUST be exported here.
set -eu

log() { echo "[entrypoint] $*"; }
die() { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

# ---- defaults (section 5.2) -------------------------------------------------
export CONC_CHIPSET="${CONC_CHIPSET:-sx1302}"
export CHANNEL_PLAN="${CHANNEL_PLAN:-eu868}"
export CONC_LOG_LEVEL="${CONC_LOG_LEVEL:-INFO}"
export CONC_STATS_INTERVAL="${CONC_STATS_INTERVAL:-30s}"
export CONC_DISABLE_CRC_FILTER="${CONC_DISABLE_CRC_FILTER:-false}"
export CONC_ANTENNA_GAIN="${CONC_ANTENNA_GAIN:-0}"
export CONC_LORAWAN_PUBLIC="${CONC_LORAWAN_PUBLIC:-true}"

[ -n "${CONC_MODEL:-}" ] || die "CONC_MODEL is required (e.g. rak_2287, seeed_wm1302, imst_ic880a, rak_2245)"
export CONC_MODEL

# ---- chipset / binary -------------------------------------------------------
case "$CONC_CHIPSET" in
  sx1301|sx1302|2g4) ;;
  *) die "CONC_CHIPSET must be sx1301, sx1302 or 2g4 (got: $CONC_CHIPSET)" ;;
esac
BIN="/usr/bin/chirpstack-concentratord-$CONC_CHIPSET"
EXAMPLES="/etc/chirpstack-concentratord/examples/$CONC_CHIPSET"

# ---- channel plan -> region + channels files (section 5.1) ------------------
PLAN=$(echo "$CHANNEL_PLAN" | tr 'A-Z' 'a-z')
case "$PLAN" in
  us915_*|au915_*|cn470_*) REGION_BASE="${PLAN%_*}" ;;  # sub-band plans
  *) REGION_BASE="$PLAN" ;;                             # incl. as923_2..4
esac
REGION_FILE="$EXAMPLES/region_${REGION_BASE}.toml"
CHANNELS_FILE="$EXAMPLES/channels_${PLAN}.toml"
[ -f "$REGION_FILE" ] || die "no region file for CHANNEL_PLAN=$PLAN on $CONC_CHIPSET ($REGION_FILE missing). Available: $(ls "$EXAMPLES" | tr '\n' ' ')"
[ -f "$CHANNELS_FILE" ] || die "no channels file for CHANNEL_PLAN=$PLAN on $CONC_CHIPSET ($CHANNELS_FILE missing). Available: $(ls "$EXAMPLES" | tr '\n' ' ')"
export CONC_REGION=$(echo "$REGION_BASE" | tr 'a-z' 'A-Z')

# ---- gateway ID precedence (section 5.1) ------------------------------------
# explicit GATEWAY_ID > chip EUI (sx1302/2g4: empty string) > MAC-derived (sx1301)
# Sanitize pasted values: strip whitespace/colons, lowercase, validate format.
GATEWAY_ID=$(printf '%s' "${GATEWAY_ID:-}" | tr -d '[:space:]:' | tr 'A-F' 'a-f')
if [ -n "$GATEWAY_ID" ] && ! printf '%s' "$GATEWAY_ID" | grep -Eq '^[0-9a-f]{16}$'; then
  die "GATEWAY_ID must be exactly 16 hex characters (got: '$GATEWAY_ID')"
fi
if [ -z "${GATEWAY_ID:-}" ] && [ "$CONC_CHIPSET" = "sx1301" ]; then
  # SX1301 has no chip EUI: derive xxxxxxFFFExxxxxx from the host MAC via the
  # supervisor API (the container's own MAC is a bridge address).
  MAC=$(wget -q -O - "${BALENA_SUPERVISOR_ADDRESS:-}/v1/device?apikey=${BALENA_SUPERVISOR_API_KEY:-}" 2>/dev/null \
        | sed -n 's/.*"mac_address":"\([0-9A-Fa-f:]\{17\}\).*/\1/p' || true)
  [ -n "$MAC" ] || die "SX1301 needs a gateway ID: set GATEWAY_ID, or enable the supervisor-api label so the MAC can be read"
  HEX=$(echo "$MAC" | tr -d ':' | tr 'A-F' 'a-f')
  GATEWAY_ID="$(echo "$HEX" | cut -c1-6)fffe$(echo "$HEX" | cut -c7-12)"
  log "derived gateway ID from host MAC: $GATEWAY_ID"
fi
export GATEWAY_ID="${GATEWAY_ID:-}"

# ---- model flags: comma list -> TOML array ----------------------------------
# Placeholder is named CONC_FLAGS_TOML (not CONC_MODEL_FLAGS_TOML): the daemon
# substitutes every $VAR in unspecified order, so no placeholder may have
# another env var's name as its prefix ($CONC_MODEL would corrupt it).
FLAGS_TOML="["
OLDIFS=$IFS; IFS=','
for f in ${CONC_MODEL_FLAGS:-}; do
  f=$(echo "$f" | tr -d ' ')
  [ -n "$f" ] && FLAGS_TOML="${FLAGS_TOML}\"${f}\","
done
IFS=$OLDIFS
export CONC_FLAGS_TOML="${FLAGS_TOML%,}]"

# ---- optional hardware overrides (omitted -> vendor model defaults) ---------
OPT=""
nl='
'
[ -n "${CONC_COM_DEV_PATH:-}" ]  && OPT="$OPT${nl}  com_dev_path = \"$CONC_COM_DEV_PATH\""
[ -n "${CONC_GNSS_DEV_PATH:-}" ] && OPT="$OPT${nl}  gnss_dev_path = \"$CONC_GNSS_DEV_PATH\""
[ -n "${CONC_I2C_DEV_PATH:-}" ]  && OPT="$OPT${nl}  i2c_dev_path = \"$CONC_I2C_DEV_PATH\""
case "$CONC_CHIPSET" in
  sx1301) RESET_PREFIX="sx1301" ;;
  sx1302) RESET_PREFIX="sx1302" ;;
  2g4)    RESET_PREFIX="mcu" ;;
esac

# Guard: GPIO7-11 on the main gpiochip are the SPI0 pads (CE1, CE0, MISO,
# MOSI, SCLK). Claiming one as a reset/power pin re-muxes it away from the
# SPI controller and silently breaks the concentrator bus UNTIL THE DEVICE
# REBOOTS (container restarts do not restore pin muxing). This mistake
# usually comes from physical-pin numbering: physical header pin 11 = GPIO17,
# pin 22 = GPIO25 (validated on a live gateway — see howto troubleshooting).
check_gpio_pin() {
  # $1 = variable name, $2 = value, $3 = chip (empty means default gpiochip0)
  case "${3:-/dev/gpiochip0}" in */gpiochip0) ;; *) return 0 ;; esac
  case "$2" in
    7|8|9|10|11)
      [ "${CONC_GPIO_FORCE:-false}" = "true" ] && { log "WARNING: $1=$2 is an SPI0 pad — forced by CONC_GPIO_FORCE"; return 0; }
      die "$1=$2 is an SPI0 pad (GPIO7-11) and would disconnect the concentrator's SPI bus until reboot. GPIO line offsets are NOT physical header pins (physical pin 11 = GPIO17, pin 22 = GPIO25). If GPIO$2 is genuinely correct for your board, set CONC_GPIO_FORCE=true."
      ;;
  esac
}
[ -n "${CONC_RESET_PIN:-}" ] && check_gpio_pin CONC_RESET_PIN "$CONC_RESET_PIN" "${CONC_RESET_CHIP:-}"
[ -n "${CONC_POWER_EN_PIN:-}" ] && check_gpio_pin CONC_POWER_EN_PIN "$CONC_POWER_EN_PIN" "${CONC_POWER_EN_CHIP:-}"

[ -n "${CONC_RESET_CHIP:-}" ] && OPT="$OPT${nl}  ${RESET_PREFIX}_reset_chip = \"$CONC_RESET_CHIP\""
[ -n "${CONC_RESET_PIN:-}" ]  && OPT="$OPT${nl}  ${RESET_PREFIX}_reset_pin = $CONC_RESET_PIN"
if [ "$CONC_CHIPSET" = "sx1302" ]; then
  [ -n "${CONC_POWER_EN_CHIP:-}" ] && OPT="$OPT${nl}  sx1302_power_en_chip = \"$CONC_POWER_EN_CHIP\""
  [ -n "${CONC_POWER_EN_PIN:-}" ]  && OPT="$OPT${nl}  sx1302_power_en_pin = $CONC_POWER_EN_PIN"
fi
export CONC_OPTIONAL_LINES="$OPT"

# ---- start ------------------------------------------------------------------
log "chipset=$CONC_CHIPSET model=$CONC_MODEL flags=$CONC_FLAGS_TOML plan=$PLAN region=$CONC_REGION"
log "gateway_id=${GATEWAY_ID:-<chip EUI>}"
log "config: templates/concentratord.toml + $(basename "$REGION_FILE") + $(basename "$CHANNELS_FILE")"
exec "$BIN" \
  -c /opt/app/templates/concentratord.toml \
  -c "$REGION_FILE" \
  -c "$CHANNELS_FILE"
