# Environment variable reference

Complete overview of every variable the Balena ChirpStack Gateway OS
application reads. Set them in the balena dashboard as **fleet variables**
(all devices), **device variables** (one device), or **service variables**
(one service on one device — recommended for secrets, and restarts only that
service on change).

Conventions:

- Booleans are the literal strings `true` / `false`.
- Lists are comma-separated (`868100000,868300000`).
- Changing a variable restarts the affected service(s), which re-render their
  configuration at startup (resin-template pattern).
- Secrets (`MQTT_PASSWORD`, `MESH_ROOT_KEY`, `HELIUM_SWARM_KEY`) are never
  written to the logs.

## ★ Minimum set

A working ChirpStack gateway needs exactly these:

| Variable | Where | Example |
|---|---|---|
| ★ `BALENA_HOST_CONFIG_dtparam` | fleet/device **configuration** | `"i2c_arm=on","spi=on"` |
| ★ `CONC_MODEL` | device variable | `rak_2287` |
| ★ `MQTT_SERVER` | device or fleet variable | `ssl://chirpstack.example.net:8883` |

Everything else has a working default. Add `MQTT_USERNAME`/`MQTT_PASSWORD`
(and possibly `MQTT_CA_CERT`) if your broker requires them, and `GATEWAY_ID`
if your concentrator has no usable chip EUI.

## Host configuration (balena "Configuration" tab, not device variables)

| Variable | Recommended | Purpose |
|---|---|---|
| ★ `BALENA_HOST_CONFIG_dtparam` | `"i2c_arm=on","spi=on"` | enable the SPI bus (concentrator) and i2c (temperature sensor, ECC608) |
| `BALENA_HOST_CONFIG_core_freq` | `500` | lock the Pi 4 VPU clock — stable SPI timing |
| `BALENA_HOST_CONFIG_core_freq_min` | `500` | as above |
| `BALENA_HOST_CONFIG_dtoverlay` | (empty on headless gateways) | balena's default `vc4-kms-v3d` display overlay is unnecessary; UART GNSS on Pi 3/4 needs `disable-bt` here |

## Global (read by multiple services)

| Variable | Default | Description |
|---|---|---|
| `GATEWAY_ID` | see precedence | 16-hex-char gateway EUI override. Precedence: explicit value → SX1302/2G4 chip EUI → MAC-derived (`xxxxxxFFFExxxxxx`, SX1301 only). Forwarders always obtain the effective ID from concentratord over ZMQ. Whitespace/colons in pasted values are stripped; invalid values fail with a clear error. |
| `CHANNEL_PLAN` | `eu868` | one of `eu868`, `us915_0`…`us915_7`, `au915_0`…`au915_7`, `cn470_0`…`cn470_11`, `as923`, `as923_2`, `as923_3`, `as923_4`, `kr920`, `in865`, `ru864`, `eu433`, `ism2400`. Selects the concentratord region+channels files and the defaults for `MQTT_TOPIC_PREFIX`, `MESH_REGION` and `GW_REGION`. |

## concentratord (`CONC_*`) — always enabled

| Variable | Default | Description |
|---|---|---|
| ★ `CONC_MODEL` | **required** | concentrator shield/module, e.g. `rak_2287`, `seeed_wm1302`, `imst_ic880a`, `rak_2245`, `rak_5146` — any model supported by chirpstack-concentratord for the selected chipset |
| `CONC_CHIPSET` | `sx1302` | `sx1301` \| `sx1302` \| `2g4` — selects the concentratord binary |
| `CONC_MODEL_FLAGS` | empty | comma list, e.g. `USB`, `GPS`, `ENFORCE_DC` |
| `CONC_ANTENNA_GAIN` | `0` | antenna gain in dBi |
| `CONC_LORAWAN_PUBLIC` | `true` | public/private LoRaWAN sync word |
| `CONC_COM_DEV_PATH` | model default | override `/dev/spidevX.Y` (SPI) or `/dev/ttyACMx` (USB) |
| `CONC_RESET_CHIP` | model default | GPIO chip device for the reset line, e.g. `/dev/gpiochip0` |
| `CONC_RESET_PIN` | model default | reset line offset (GPIO character-device numbering, **not** physical pin) |
| `CONC_POWER_EN_CHIP` | model default | SX1302 power-enable GPIO chip (models that support it) |
| `CONC_POWER_EN_PIN` | model default | SX1302 power-enable line offset |
| `CONC_GNSS_DEV_PATH` | model default | GNSS serial device, e.g. `/dev/ttyAMA0`; empty string disables GNSS |
| `CONC_I2C_DEV_PATH` | model default | i2c device for the temperature sensor |
| `CONC_STATS_INTERVAL` | `30s` | stats publish interval (humantime format) |
| `CONC_DISABLE_CRC_FILTER` | `false` | also forward CRC-invalid frames |
| `CONC_LOG_LEVEL` | `INFO` | `TRACE`/`DEBUG`/`INFO`/`WARN`/`ERROR`/`OFF` |

## mqtt-forwarder (`MQTT_*`) — enabled by default

| Variable | Default | Description |
|---|---|---|
| `MQTT_ENABLED` | `true` | set `false` to idle the service |
| ★ `MQTT_SERVER` | **required** | broker URI: `tcp://host:1883`, `ssl://host:8883`, `ws://…`, `wss://…` |
| `MQTT_TOPIC_PREFIX` | from `CHANNEL_PLAN` | region topic prefix (`eu868`, `us915_0`, …) |
| `MQTT_USERNAME` | empty | broker username |
| `MQTT_PASSWORD` | empty | broker password (use a service variable) |
| `MQTT_QOS` | `0` | MQTT QoS 0–2 |
| `MQTT_JSON` | `false` | JSON payloads instead of protobuf |
| `MQTT_CA_CERT` | empty | CA certificate **PEM content** (written to a file at start) |
| `MQTT_TLS_CERT` | empty | client certificate PEM content |
| `MQTT_TLS_KEY` | empty | client key PEM content |
| `MQTT_FILTER_LORAWAN_ONLY` | `true` | drop proprietary (non-LoRaWAN) frames |
| `MQTT_FILTER_DEV_ADDR_PREFIXES` | empty | comma list of DevAddr prefixes, e.g. `01000000/8` |
| `MQTT_FILTER_JOIN_EUI_PREFIXES` | empty | comma list of JoinEUI prefixes |
| `MQTT_BACKEND` | `concentratord` | `mesh` consumes the gateway-mesh proxy instead (border gateway) |
| `MQTT_LOG_LEVEL` | `info` | log level |

## udp-forwarder (`UDP_*`) — disabled by default

Indexed upstream slots, `n` = `0`–`3` (resin-template pattern).

| Variable | Default | Description |
|---|---|---|
| `UDP_ENABLED` | `false` | set `true` to activate; requires ≥ 1 enabled server slot |
| `UDP_SERVER_ADDRESS_n` | — | hostname/IP of upstream `n`, e.g. `eu1.cloud.thethings.network` or `helium-gateway` |
| `UDP_SERVER_PORT_n` | `1700` | UDP port of upstream `n` (Helium gateway-rs listens on `1680`) |
| `UDP_SERVER_ENABLED_n` | `true` when address set | disable a slot without deleting its variables |
| `UDP_FILTER_LORAWAN_ONLY` | `true` | drop proprietary frames (applied per server) |
| `UDP_METRICS_BIND` | empty (disabled) | Prometheus endpoint, e.g. `0.0.0.0:9800` |
| `UDP_LOG_LEVEL` | `INFO` | log level |

## ttn-forwarder (`TTN_*`) — disabled by default

Bridges concentratord to the TTN protobuf-MQTT gateway protocol (The Things
Stack Gateway Server MQTT frontend / "packet broker", or a self-hosted
gateway-connector-bridge) — the drop-in replacement for gateways commissioned
with the mp_pkt_fwd + ttn-gateway-connector stack. Source:
[chirpstack-ttn-mqtt-forwarder](https://github.com/pe1mew/chirpstack-ttn-mqtt-forwarder)
(submodule; compiled at image build).

Supports **multiple simultaneous upstream connections** (v0.2.0): indexed
connection slots `n` = `0`–`3` (resin-template pattern), each with its own
registration and endpoint. The unsuffixed variables (`TTN_GATEWAY_ID`,
`TTN_GATEWAY_KEY`, `TTN_SERVER`, `TTN_TLS_ENABLED`, `TTN_DOWNLINK_ENABLED`,
`TTN_CA_CERT`, `TTN_NAME`) act as **aliases for slot 0**, so
single-connection deployments need no `_n` suffixes.

Per connection (`n` = `0`–`3`):

| Variable | Default | Description |
|---|---|---|
| `TTN_GATEWAY_ID_n` | — (defines the slot) | gateway ID as registered with the network (MQTT username) |
| `TTN_GATEWAY_KEY_n` | **required per slot** | gateway key / API key (MQTT password; use a device variable) |
| `TTN_SERVER_n` | `eu1.cloud.thethings.network:1881` | protobuf-MQTT endpoint, `host:port` (TLS: port `8881` + TLS flag) |
| `TTN_CONNECTION_ENABLED_n` | `true` when ID set | disable a slot without deleting its variables |
| `TTN_NAME_n` | `connN` | connection name shown in the logs |
| `TTN_DOWNLINK_ENABLED_n` | `true` | subscribe to and transmit downlinks on this connection |
| `TTN_TLS_ENABLED_n` | `false` | TLS to this endpoint; system CA bundle unless a CA is supplied |
| `TTN_CA_CERT_n` | empty | CA certificate **PEM content** (not a path) for private endpoints |
| `TTN_KEEP_ALIVE_n` / `TTN_RECONNECT_MAX_n` | `20s` / `5m` (or the unsuffixed globals) | MQTT keep-alive / max reconnect backoff |

Shared across all connections:

| Variable | Default | Description |
|---|---|---|
| `TTN_ENABLED` | `false` | set `true` to activate the service |
| `TTN_BACKEND` | `concentratord` | `concentratord` or `mesh` (border-gateway proxy) |
| `TTN_CRC_OK` / `TTN_CRC_INVALID` / `TTN_CRC_MISSING` | `true` / `false` / `false` | CRC forwarding filters |
| `TTN_FILTER_LORAWAN_ONLY` | `false` | drop proprietary frames (`false` = like-for-like mp_pkt_fwd behaviour) |
| `TTN_FILTER_DEV_ADDR_PREFIXES` | empty | comma list, e.g. `0000ff00/24` |
| `TTN_FILTER_JOIN_EUI_PREFIXES` | empty | comma list, e.g. `0000ff0000000000/24` |
| `TTN_FREQUENCY_PLAN` | derived from `CHANNEL_PLAN` | status-message frequency plan string, e.g. `EU_863_870` |
| `TTN_DESCRIPTION` / `TTN_CONTACT_EMAIL` | empty | status-message metadata |
| `TTN_LATITUDE` / `TTN_LONGITUDE` / `TTN_ALTITUDE` | `0.0` / `0.0` / `0` | static location when concentratord provides none (GNSS) |
| `TTN_KEEP_ALIVE` | `20s` | MQTT keep-alive |
| `TTN_RECONNECT_MAX` | `5m` | maximum reconnect backoff |
| `TTN_LOG_LEVEL` | `info` | log level |

Note: with multiple connections every network receives all uplinks and each
may schedule downlinks (first-come-first-served on the JIT queue) — same
semantics as multi-server Semtech-UDP.

## gateway-mesh (`MESH_*`) — disabled by default

| Variable | Default | Description |
|---|---|---|
| `MESH_ENABLED` | `false` | set `true` to activate |
| `MESH_ROOT_KEY` | **required when enabled** | 32-hex-char AES128 key, identical on all mesh gateways (use a fleet variable) |
| `MESH_BORDER_GATEWAY` | `false` | `true` = border gateway (also set `MQTT_BACKEND=mesh`), `false` = relay |
| `MESH_IGNORE_DIRECT_UPLINKS` | `false` | border gateway: ignore uplinks received directly |
| `MESH_MAX_HOP_COUNT` | `1` | maximum mesh hops |
| `MESH_TX_POWER` | `16` | mesh TX power (EIRP) |
| `MESH_FREQUENCIES` | region default | comma list of mesh frequencies in Hz |
| `MESH_RELAY_ID` | derived from gateway ID | 8-hex-char (4-byte) relay ID override |
| `MESH_REGION` | from `CHANNEL_PLAN` | selects the region mapping file (`eu868`, `us915`, …) |
| `MESH_DATA_RATE_MODULATION` | `LORA` | `LORA` or `FSK` |
| `MESH_DATA_RATE_SF` | `7` | spreading factor (LoRa) |
| `MESH_DATA_RATE_BANDWIDTH` | `125000` | bandwidth in Hz |
| `MESH_DATA_RATE_CODE_RATE` | `4/5` | code rate |
| `MESH_LOG_LEVEL` | `INFO` | log level |

## helium-gateway (`HELIUM_*` + native `GW_*`) — disabled by default

The entrypoint resolves the Helium identity on every start (priority: ECC608
secure element → supplied swarm key → generated keypair) and passes all other
`GW_*` variables straight through to gateway-rs, which maps any
`settings.toml` entry from the environment (`GW_<SECTION>_<KEY>`).

| Variable | Default | Description |
|---|---|---|
| `HELIUM_ENABLED` | `false` | set `true` to activate; also wire the UDP forwarder: `UDP_ENABLED=true`, `UDP_SERVER_ADDRESS_n=helium-gateway`, `UDP_SERVER_PORT_n=1680` |
| `HELIUM_ECC` | `auto` | secure-element use: `auto` probes at start (supervised trial), `true` forces it (fails fast when absent), `false` skips it |
| `HELIUM_ECC_URI` | `ecc://i2c-1:96?slot=0` | keypair URI used when the ECC608 is selected |
| `HELIUM_ONBOARDING_URI` | `ecc://i2c-1:96?slot=15` | onboarding key URI (ECC mode) |
| `HELIUM_SWARM_KEY` | empty | base64-encoded content of an existing swarm-key/keypair file; overwrites the file keypair at every start (no secure element only). Set as a **device** variable — identities are per-device |
| `GW_KEYPAIR` | resolved by entrypoint | normally not set by hand; explicit value overrides the file-keypair path |
| `GW_LISTEN` | `0.0.0.0:1680` | GWMP listener bind |
| `GW_REGION` | from `CHANNEL_PLAN` | Helium region (`EU868`, `US915`, …) |
| `GW_POC_DISABLE` | `true` | PoC beaconing disabled by default (sunset). `false` re-enables. A periodic `beaconer: failed to reconnect` warning remains either way (harmless, unconditional in gateway-rs v1.3.0) |
| `GW_LOG_LEVEL` | `info` | gateway-rs log level |
| any other `GW_*` | upstream default | native gateway-rs override, e.g. `GW_API=4467` |

## Quick recipes

- **ChirpStack only (minimum):** `CONC_MODEL`, `MQTT_SERVER` (+ host `dtparam`).
- **Add TTN (Semtech UDP):** `UDP_ENABLED=true`, `UDP_SERVER_ADDRESS_0=eu1.cloud.thethings.network`.
- **Add TTN (protobuf MQTT, The Things Gateway replacement):**
  `TTN_ENABLED=true`, `TTN_GATEWAY_ID=<console id>`, `TTN_GATEWAY_KEY=<key>` —
  keeps the existing gateway registration of mp_pkt_fwd-era gateways.
- **Add Helium (converted hotspot):** `HELIUM_ENABLED=true`,
  `UDP_ENABLED=true`, `UDP_SERVER_ADDRESS_1=helium-gateway`,
  `UDP_SERVER_PORT_1=1680` — identity comes from the ECC608 automatically.
- **Mesh relay:** `MESH_ENABLED=true`, `MESH_ROOT_KEY=<fleet key>`.
- **Mesh border gateway:** relay set + `MESH_BORDER_GATEWAY=true`,
  `MQTT_BACKEND=mesh`.
