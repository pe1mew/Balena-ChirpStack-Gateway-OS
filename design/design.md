# Design: Balena ChirpStack Gateway

Multi-container balenaCloud application that provides the same gateway tasks as
**ChirpStack Gateway OS**, configured entirely through Balena **environment
variables**, following the pattern of the **ttn-resin-gateway-rpi** template.

Status: **reviewed — all open decisions resolved** (see
[section 10](#10-open-decisions-for-review)).

---

## 1. Goal and scope

ChirpStack Gateway OS (OpenWrt) runs these LoRa gateway tasks:

| Gateway OS task | Purpose | In scope? |
|---|---|---|
| chirpstack-concentratord (sx1301 / sx1302 / 2g4) | Concentrator HAL daemon, ZMQ API | **Yes** — core service |
| chirpstack-mqtt-forwarder | Events → ChirpStack MQTT broker | **Yes** — core service |
| chirpstack-udp-forwarder | Events → Semtech-UDP server(s) | **Yes** — optional service |
| chirpstack-gateway-mesh | Border/relay mesh gateway | **Yes** — optional service |
| ChirpStack NS + Mosquitto + Redis ("full" image) | On-gateway LoRaWAN network server | **No** — this is a gateway-only design; it always forwards to a remote ChirpStack/NS |
| — (not in Gateway OS) helium gateway-rs | Forward to the Helium IoT network | **Yes** — optional service (this design's addition) |
| LuCI web UI | Configuration UI | **No** — replaced by Balena dashboard env vars |
| WiFi AP fallback, network config | OpenWrt networking | **No** — handled by balenaOS (optionally `wifi-connect` later) |
| watchcat, collectd/statistics | Monitoring/self-healing | **No** — Balena supervisor provides restart policy + device metrics |
| opkg package manager, firmware upgrade buttons | OS management | **No** — Balena release management replaces it |

Hardware targets: **Raspberry Pi family** (Zero/1, 2/3/4, 5 — the Balena-supported
subset of Gateway OS targets; RAK/ramips boards are not balenaOS targets) with any
SPI/USB concentrator shield supported by concentratord (iC880A, RAK2245/2247,
RAK2287, RAK5146, Seeed WM1302, Waveshare SX1302 HAT, Semtech CoreCell, …).
This includes converted Helium hotspots, which are the same class of hardware
with a different concentrator module:

| Hotspot | Board | Concentrator | `CONC_MODEL` |
|---|---|---|---|
| MNTD./RAK Hotspot Miner V2 | Raspberry Pi 4 (2/4/8 GB, SD-card boot) | RAK2287 (SX1302) | `rak_2287` |
| Seeed SenseCAP M1 | Raspberry Pi 4 (2/4/8 GB, SD-card boot) | WM1302/WM1303 (SX1302/SX1303) | `seeed_wm1302` |

Both carry an ECC608 secure element whose Helium identity survives the
conversion and is used directly by gateway-rs (see D7); all use
`CONC_CHIPSET=sx1302`. Other Pi-based hotspots (RAK V1, Nebra indoor, …)
should work the same way — pick the matching `CONC_MODEL`.

All four ChirpStack components plus helium `gateway-rs` are linked as git
submodules for **reference** (design inspection, config examples) — not as
build source. Binaries are taken from the upstreams' **version- and
checksum-pinned release artifacts** (see D8 / Appendix A); the region/channel
TOML example files are copied from the submodules at image build (static
files, no compilation).

---

## 2. What we take from the resin template

From `ttn-resin-gateway-rpi` we reuse the *pattern*, not the code:

1. **Env vars → config file at container start.** The template's `run.py` builds
   `global_conf.json` from `GW_*` env vars on every container start. We do the
   same: a small entrypoint script per service renders the TOML config from env
   vars, then `exec`s the daemon. Changing a device variable in the Balena
   dashboard restarts the container and re-renders the config.
2. **`Dockerfile.template` with `%%BALENA_MACHINE_NAME%%`** multi-stage builds:
   heavy build stage, slim runtime stage (`ENV UDEV=off`).
3. **Gateway EUI derivation from MAC** with `FFFE` midfix when no explicit ID is
   set (Gateway OS does the identical thing in its uci-defaults).
4. **Sane defaults + minimal mandatory variables** — a device should come up with
   only a handful of variables set.

What we deliberately do differently:

| resin template | this design | why |
|---|---|---|
| Single privileged container | Multi-container compose, only concentratord privileged | Least privilege; independent restarts; mirrors Gateway OS service split |
| Python 2 `run.py` generating JSON | POSIX shell entrypoint + the components' **native `$VAR` TOML substitution** | All four ChirpStack components already substitute `$NAME` in their TOML before parsing — most "templating" is free |
| Builds unpinned master of 6 repos at image build | Downloads version+SHA-256-pinned upstream release binaries | Reproducibility, seconds-fast builds; no patching intended |
| Blocking retry loop fetching TTN account server | No remote fetches; all config local | TTN v2 is dead; ChirpStack config is self-contained |
| Secrets printed to log | Never log `MQTT_PASSWORD` / `MESH_ROOT_KEY` / `HELIUM_SWARM_KEY` | Balena logs are cloud-visible |

---

## 3. Container architecture

```
                 ┌────────────────────────────────────────────────┐
                 │ balenaOS device (Raspberry Pi)                 │
                 │                                                │
 /dev/spidev0.0  │  ┌──────────────────┐   ZMQ tcp://             │
 /dev/gpiochip0 -+->│  concentratord   │<───────────┬──────────┐  │
 /dev/ttyACM0    │  │  (privileged)    │            │          │  │
 /dev/ttyAMA0    │  └──────────────────┘            │          │  │
                 │       events :3001               │          │  │
                 │       commands :3002             │          │  │
                 │                          ┌───────┴───┐ ┌────┴────────┐
                 │                          │ mqtt-fwd  │ │ udp-fwd     │
                 │                          └───────┬───┘ │ (optional)  │
                 │                                  │     └────┬────────┘
                 │  ┌──────────────────┐            │          │
                 │  │ gateway-mesh     │── proxy    │          │
                 │  │ (optional)       │   :3011/12 │          │
                 │  └──────────────────┘            │          │
                 └──────────────────────────────────┼──────────┼──┘
                                                    ▼          ▼
                                        MQTT broker          Semtech-UDP server(s)
                                        (remote ChirpStack)  and/or helium-gateway
                                                             (gateway-rs → Helium)
```

### Services (docker-compose.yml)

| Service | Image contents | Privileges | Default state |
|---|---|---|---|
| `concentratord` | all three concentratord binaries + all `region_*.toml` / `channels_*.toml` example configs | `privileged: true` (SPI, GPIO cdev, UART/USB) | enabled |
| `mqtt-forwarder` | `chirpstack-mqtt-forwarder` | none | enabled |
| `udp-forwarder` | `chirpstack-udp-forwarder` | none | **disabled** (idles) |
| `ttn-forwarder` | `chirpstack-ttn-mqtt-forwarder` (this project; TTN protobuf-MQTT gateway protocol) | none | **disabled** (idles) |
| `gateway-mesh` | `chirpstack-gateway-mesh` + region mapping TOMLs | none | **disabled** (idles) |
| `helium-gateway` | helium `gateway-rs` | i2c device (`/dev/i2c-1`) for the ECC608 secure element; named volume for file-keypair fallback | **disabled** (idles) |

### Key architectural decisions

**D1 — ZMQ over `tcp://`, not `ipc://`.**
Gateway OS runs everything in one OS, so it uses `ipc:///tmp/concentratord_*`.
Across containers `ipc://` would require a shared volume for the socket files;
`tcp://` over Balena's internal compose network is simpler and equally supported
by every component. Concentratord binds `tcp://0.0.0.0:3001` (events) and
`tcp://0.0.0.0:3002` (commands); forwarders connect to
`tcp://concentratord:3001/3002`. The mesh proxy API binds `:3011/:3012`.

**D2 — one concentratord image containing all three binaries.**
`CONC_CHIPSET=sx1301|sx1302|2g4` selects the binary at start. The binaries are
static musl builds (~few MB each); one image for all shields keeps the fleet
simple and matches the Gateway OS "select chipset in UI" experience. A second
concentratord service ("slot 2", e.g. ISM2400 for mesh) can be added later by
duplicating the service block with its own env-var prefix.

**D3 — enable/disable via env var + idle pattern.**
Balena starts every compose service; there is no conditional service start.
Optional services check their `*_ENABLED` variable in the entrypoint and
`exec sleep infinity` when not `true` (standard Balena idle pattern, negligible
footprint). This mirrors the per-service `enabled` UCI flag of Gateway OS.

**D4 — configuration rendering: native `$VAR` substitution + thin entrypoint.**
All four components replace `$NAME` with the environment value inside their TOML
before parsing. So the images ship TOML templates with `$MQTT_SERVER`-style
placeholders, and the entrypoint only does what substitution can't:
- select which files to pass as `-c` (chipset binary, `region_<plan>.toml`,
  `channels_<plan>.toml`, sub-band files for US915/AU915/CN470),
- derive the gateway EUI from the MAC when `GATEWAY_ID` is unset,
- apply defaults for unset variables (substitution inserts the literal `$NAME`
  string when a variable is missing, so the entrypoint must `export` defaults),
- map booleans/lists into TOML syntax where needed (e.g. mesh `frequencies`,
  the indexed `UDP_SERVER_*_n` variables → `[[udp_forwarder.servers]]` blocks).

**D5 — only concentratord is privileged.**
It needs `/dev/spidev0.0` (SPI shields), `/dev/gpiochip*` (reset/power-en via
gpiocdev), `/dev/ttyACM0` (USB shields), `/dev/ttyAMA0` (GNSS), `/dev/i2c-*`
(temperature sensor on CoreCell). `privileged: true` with `UDEV=on` is the
robust choice on Balena for mixed SPI/USB fleets; all other services run
unprivileged.

**D6 — GPIO reset is concentratord's job, not the entrypoint's.**
Unlike the resin template (Python `RPi.GPIO` reset loop around the forwarder),
concentratord performs the SX130x reset itself through the GPIO character
device, with per-model defaults overridable by env vars. No reset scripting
needed.

**D7 — Helium via the existing UDP-forwarder seam; identity from the secure element when present.**
`gateway-rs` receives packets as a Semtech-UDP (GWMP) listener and forwards
upstream via gRPC to the Helium Packet Router, so no new data plumbing is
needed: enable `udp-forwarder` and add a server entry
(`UDP_SERVER_ADDRESS_n=helium-gateway`, `UDP_SERVER_PORT_n=1680`).
The same device can feed ChirpStack (MQTT) and Helium (UDP) simultaneously.
gateway-rs natively overrides any `settings.toml` entry from `GW_*` environment
variables, so it needs no TOML templating at all — only the enable/idle gate
and keypair handling. The entrypoint resolves the identity **on every start**
with this fixed priority:

1. **ECC608 secure element.** Detected automatically (probe of the i2c bus,
   overridable via `HELIUM_ECC=true|false|auto`). On converted hotspots such as
   the MNTD/RAK V2 the miner identity lives in the ECC608 on the board and
   **survives flashing balenaOS** — the entrypoint sets
   `GW_KEYPAIR=ecc://i2c-1:96?slot=0` and `GW_ONBOARDING=ecc://i2c-1:96?slot=15`
   and the unit keeps operating as its original **onboarded hotspot**. Requires
   i2c device access for the container and `i2c_arm=on` in the host DT config.
2. **Supplied swarm key.** No secure element found (e.g. RAK V1-era hotspots or
   plain Pi builds) and `HELIUM_SWARM_KEY` is set: the entrypoint decodes the
   base64-encoded swarm-key/keypair file content and writes it over the keypair
   file, overriding whatever was generated or stored before — this transfers an
   existing identity onto the device.
3. **Generated keypair.** No secure element, no swarm key provided: gateway-rs
   generates a keypair on first start, persisted in the named volume; onboard
   with `helium-wallet` as **data-only** (small one-time fee, data-transfer
   rewards only).

Never run the stock miner firmware and this instance at the same time with the
same identity. The exact i2c bus/address/slot layout should be verified once
per hotspot model (`i2cdetect`; slot 0 identity / slot 15 onboarding is the
Helium convention).

**D8 — binaries from pinned upstream release artifacts, not compiled.**
Dockerfiles download the upstreams' per-target musl release tarballs, pinned
by version **and SHA-256**, giving seconds-fast builds. The submodules serve
as reference and as the source for static config files only — no patching is
intended, and ChirpStack upstream is actively maintained. Because gateway-rs
may stop being maintained, its release artifact (and optionally the others)
is **mirrored as a release asset of this repository**, and the Dockerfile ARG
allows switching the download base URL to the mirror. Rationale and
alternatives in Appendix A.
*Exceptions:* chirpstack-udp-forwarder — upstream publishes **no** binary
artifacts at all (empty artifacts directory; Gateway OS also compiles it) —
and chirpstack-ttn-mqtt-forwarder — developed in this project, no published
artifacts. Both services build from their pinned submodules (the Appendix A
fallback); both submodules must be initialised before `balena push`.

**D9 — GPS/GNSS is intentionally not supported.**
Some gateways carry a GPS receiver, and concentratord can read it
(`GPS` model flag / `gnss_dev_path`), but this design deliberately does not
implement or validate GPS support. Rationale: gateway coordinates are static
in practice and better maintained in the LNS registration; the fleet's
Pi 3-based gateways would need UART reconfiguration (`enable_uart`,
Bluetooth overlay) per device; the `imst_ic880a` concentratord profile
ignores GNSS settings entirely; and time synchronisation comes from NTP on
connected gateways. The `CONC_GNSS_DEV_PATH` / `CONC_MODEL_FLAGS=GPS`
variables pass through to concentratord unchanged for experimenters, but
they are **unsupported and unvalidated** in this project. Revisiting this
decision would involve: the Pi 3 UART host configuration, an upstream
contribution adding GNSS to the ic880a profile, and optionally live-location
support in the ttn-forwarder.

---

## 4. Repository layout (target)

```
Balena-ChirpStack-Gateway-OS/
├── docker-compose.yml
├── balena.yml                        # fleet metadata
├── design/design.md                  # this document
├── concentratord/
│   ├── Dockerfile.template           # build stage: cargo build from submodule
│   ├── entrypoint.sh
│   └── templates/concentratord.toml  # $VAR placeholders
├── mqtt-forwarder/
│   ├── Dockerfile.template
│   ├── entrypoint.sh
│   └── templates/chirpstack-mqtt-forwarder.toml
├── udp-forwarder/
│   ├── Dockerfile.template
│   ├── entrypoint.sh
│   └── templates/chirpstack-udp-forwarder.toml
├── gateway-mesh/
│   ├── Dockerfile.template
│   ├── entrypoint.sh
│   └── templates/chirpstack-gateway-mesh.toml
├── helium-gateway/
│   ├── Dockerfile.template           # build from gateway-rs submodule
│   └── entrypoint.sh                 # enable/idle gate + identity resolution (ECC → swarm key → generate)
├── chirpstack-concentratord/         # submodule (reference + region/channel TOML source)
├── chirpstack-mqtt-forwarder/        # submodule (reference)
├── chirpstack-udp-forwarder/         # submodule (reference)
├── chirpstack-gateway-mesh/          # submodule (reference + region mapping TOML source)
├── chirpstack-gateway-os/            # submodule (reference only)
├── gateway-rs/                       # submodule (reference + settings.toml example)
└── ttn-resin-gateway-rpi/            # submodule (reference only)
```

### docker-compose.yml sketch

```yaml
version: "2.1"
services:
  concentratord:
    build: ./concentratord
    privileged: true
    restart: always
    ports: []            # internal network only
    labels:
      io.balena.features.kernel-modules: "1"

  mqtt-forwarder:
    build: ./mqtt-forwarder
    restart: always
    depends_on: [concentratord]

  udp-forwarder:
    build: ./udp-forwarder
    restart: always
    depends_on: [concentratord]

  gateway-mesh:
    build: ./gateway-mesh
    restart: always
    depends_on: [concentratord]

  helium-gateway:
    build: ./helium-gateway
    restart: always
    devices:
      - "/dev/i2c-1:/dev/i2c-1"           # ECC608 secure element (hotspot hardware)
    volumes:
      - helium-data:/etc/helium_gateway   # persists the file-based keypair fallback

volumes:
  helium-data:
```

Host-level config (documented in README, set as fleet config vars):
`BALENA_HOST_CONFIG_dtparam = "spi=on","i2c_arm=on"` and, when a GNSS UART is
used on Pi 3/4, `BALENA_HOST_CONFIG_dtoverlay = disable-bt` +
`core_freq` handling — the modern equivalent of the resin template's
`RESIN_HOST_CONFIG_*` variables.

### Dockerfile.template sketch (same shape for all five services)

```dockerfile
FROM alpine AS fetch
# version + checksum pinned per component/target triple (see Appendix A table)
ARG VERSION=x.y.z TRIPLE=aarch64-unknown-linux-musl SHA256=...
RUN wget -O /tmp/dist.tar.gz \
      "https://github.com/chirpstack/chirpstack-concentratord/releases/download/v${VERSION}/...${TRIPLE}.tar.gz" \
 && echo "${SHA256}  /tmp/dist.tar.gz" | sha256sum -c \
 && tar -xzf /tmp/dist.tar.gz -C /out

FROM balenalib/%%BALENA_MACHINE_NAME%%-debian:bookworm-run
ENV UDEV=on
COPY --from=fetch /out/chirpstack-concentratord-* /usr/bin/
# static config examples come from the submodule in the repo context (no compilation)
COPY chirpstack-concentratord/*/config/*.toml /etc/chirpstack-concentratord/examples/
COPY concentratord/entrypoint.sh concentratord/templates/ /opt/app/
CMD ["/opt/app/entrypoint.sh"]
```

Note: build context is the repo root (`build.context: .` +
`dockerfile: <service>/Dockerfile.template`) so the Dockerfiles can COPY the
static TOML examples out of the submodules.

---

## 5. Environment variables

Naming: one prefix per service, mirroring what the Gateway OS LuCI UI exposes.
Booleans are the strings `true`/`false` (resin-template convention). Variables
marked **req** have no default.

### 5.1 Global (fleet-wide or per-device)

| Variable | Default | Description |
|---|---|---|
| `GATEWAY_ID` | see precedence below | 8-byte hex gateway EUI override; forwarders and mesh always obtain the effective ID from concentratord over ZMQ, so this single variable governs all services |
| `CHANNEL_PLAN` | `eu868` | `eu868, us915_0..7, au915_0..7, cn470_0..11, as923, as923_2..4, kr920, in865, ru864, eu433, ism2400` — selects concentratord region+channels files and the default MQTT `topic_prefix` (mirrors the Gateway OS UI, which writes both from one setting) |

Gateway-ID precedence (per chipset):

- **Explicit `GATEWAY_ID`** always wins — passed into concentratord's config;
  all forwarders inherit it via ZMQ.
- **SX1302/2g4, unset:** the entrypoint passes no `gateway_id`; concentratord
  uses the concentrator chip's factory EUI. The ID stays stable across Pi or
  NIC swaps.
- **SX1301, unset:** no chip EUI exists, so the entrypoint derives the EUI from
  the MAC (`xxxxxxFFFExxxxxx`), like Gateway OS and the resin template.

### 5.2 concentratord (`CONC_*`)

| Variable | Default | Description |
|---|---|---|
| `CONC_CHIPSET` | `sx1302` | `sx1301` \| `sx1302` \| `2g4` — selects binary |
| `CONC_MODEL` | **req** | shield model, e.g. `rak_2287`, `imst_ic880a`, `seeed_wm1302` (concentratord model list) |
| `CONC_MODEL_FLAGS` | empty | comma list, e.g. `USB`, `GPS`, `ENFORCE_DC` |
| `CONC_ANTENNA_GAIN` | `0` | dBi |
| `CONC_LORAWAN_PUBLIC` | `true` | public/private sync word |
| `CONC_COM_DEV_PATH` | model default | override `/dev/spidevX.Y` or `/dev/ttyACMx` |
| `CONC_RESET_CHIP` / `CONC_RESET_PIN` | model default | GPIO chip path + line offset (cdev numbering, not physical pin — differs from resin template) |
| `CONC_POWER_EN_CHIP` / `CONC_POWER_EN_PIN` | model default | sx1302 power-enable line |
| `CONC_GNSS_DEV_PATH` | model default | e.g. `/dev/ttyAMA0`; empty disables GNSS |
| `CONC_I2C_DEV_PATH` | model default | temperature sensor |
| `CONC_STATS_INTERVAL` | `30s` | stats publish interval |
| `CONC_DISABLE_CRC_FILTER` | `false` | forward CRC-invalid frames |
| `CONC_LOG_LEVEL` | `INFO` | log level (always `log_to_syslog=false` → Balena log stream) |

### 5.3 mqtt-forwarder (`MQTT_*`)

| Variable | Default | Description |
|---|---|---|
| `MQTT_ENABLED` | `true` | idle when `false` |
| `MQTT_SERVER` | **req** | `tcp://host:1883`, `ssl://…:8883`, `ws(s)://…` |
| `MQTT_TOPIC_PREFIX` | from `CHANNEL_PLAN` | region topic prefix |
| `MQTT_USERNAME` / `MQTT_PASSWORD` | empty | credentials (device variables, never logged) |
| `MQTT_QOS` | `0` | 0–2 |
| `MQTT_JSON` | `false` | JSON instead of protobuf |
| `MQTT_CA_CERT` / `MQTT_TLS_CERT` / `MQTT_TLS_KEY` | empty | PEM content written to files by entrypoint |
| `MQTT_FILTER_LORAWAN_ONLY` | `true` | proprietary-frame filter |
| `MQTT_FILTER_DEV_ADDR_PREFIXES` / `MQTT_FILTER_JOIN_EUI_PREFIXES` | empty | comma lists |
| `MQTT_BACKEND` | `concentratord` | set `mesh` to consume the gateway-mesh proxy API instead (border gateway chain) |

### 5.4 udp-forwarder (`UDP_*`)

Per-server variables follow the resin template's indexed `SERVER_n` pattern
(one variable set per upstream server, `n` = `0..3`) instead of a single list
variable:

| Variable | Default | Description |
|---|---|---|
| `UDP_ENABLED` | `false` | idle when `false` |
| `UDP_SERVER_ADDRESS_n` | **req per server** | hostname or IP of server `n` (e.g. `helium-gateway`, `eu1.cloud.thethings.network`) |
| `UDP_SERVER_PORT_n` | `1700` | UDP port of server `n` |
| `UDP_SERVER_ENABLED_n` | `true` when `ADDRESS_n` set | disable server `n` without removing its variables |
| `UDP_FILTER_LORAWAN_ONLY` | `true` | as above |
| `UDP_METRICS_BIND` | empty | optional Prometheus endpoint, e.g. `0.0.0.0:9800` |

The entrypoint iterates `n = 0..3` and renders one `[[udp_forwarder.servers]]`
block (`server = "ADDRESS:PORT"`) for every enabled entry with an address; at
least one enabled server is required when `UDP_ENABLED=true`.

### 5.5 gateway-mesh (`MESH_*`)

| Variable | Default | Description |
|---|---|---|
| `MESH_ENABLED` | `false` | idle when `false` |
| `MESH_BORDER_GATEWAY` | `false` | border vs relay role |
| `MESH_ROOT_KEY` | **req when enabled** | AES128 hex, fleet-wide |
| `MESH_RELAY_ID` | derived | 4-byte relay ID override |
| `MESH_REGION` | from `CHANNEL_PLAN` | selects `region_*.toml` mapping file |
| `MESH_FREQUENCIES` | region default | comma list in Hz |
| `MESH_TX_POWER` | `16` | EIRP |
| `MESH_DATA_RATE_*` (`MODULATION`, `SF`, `BANDWIDTH`, `CODE_RATE`) | LORA/SF7/125k/4-5 | mesh data-rate |
| `MESH_MAX_HOP_COUNT` | `1` | |
| `MESH_IGNORE_DIRECT_UPLINKS` | `false` | border gateway option |

Border-gateway wiring (mirrors Gateway OS `-mesh` variant): concentratord →
gateway-mesh (`backend.concentratord` → `tcp://concentratord:3001/3002`), mesh
proxy binds `tcp://0.0.0.0:3011/3012`, and mqtt-forwarder with `MQTT_BACKEND=mesh`
connects to `tcp://gateway-mesh:3011/3012`.

### 5.6 helium-gateway (`HELIUM_*` gate + native `GW_*`)

gateway-rs reads any `settings.toml` entry from environment variables prefixed
`GW_` natively, so apart from the enable gate and the identity resolution
(D7 priority: secure element → swarm key → generate) these variables are
passed straight through — no entrypoint templating.

| Variable | Default | Description |
|---|---|---|
| `HELIUM_ENABLED` | `false` | idle when `false` |
| `GW_REGION` | from `CHANNEL_PLAN` | Helium region (`EU868`, `US915`, …); avoids wrong-region uplinks before the first region fetch |
| `GW_LISTEN` | `0.0.0.0:1680` | GWMP listener — must bind the container network (gateway-rs's own default is `127.0.0.1:1680`) |
| `HELIUM_ECC` | `auto` | secure-element use: `auto` probes the i2c bus at start; `true` forces it (fail fast when absent); `false` skips it |
| `HELIUM_ECC_URI` | `ecc://i2c-1:96?slot=0` | keypair URI used when the ECC608 is selected; onboarding URI derived as the same bus with `slot=15` |
| `HELIUM_SWARM_KEY` | empty | priority 2 (no secure element): base64-encoded content of an existing swarm-key/keypair file; the entrypoint decodes it and **overwrites** the keypair file at every container start, transferring that identity |
| `GW_KEYPAIR` | resolved by entrypoint | normally not set by hand — the entrypoint sets it per the D7 priority (ECC URI, else `/etc/helium_gateway/keypair.bin`, generated on first start and persisted in the `helium-data` volume); may be overridden explicitly for special cases |
| `GW_POC_DISABLE` | `true` | PoC beaconing disabled by default (sunset); `false` re-enables the beaconer |
| `GW_LOG_LEVEL` | `info` | log level |

Wiring: set `UDP_ENABLED=true`, `UDP_SERVER_ADDRESS_0=helium-gateway`,
`UDP_SERVER_PORT_0=1680`. With the ECC608 (converted hotspot) no onboarding is needed —
the identity is already onboarded. For file-based keys only: read the public
key with `helium_gateway key info` (Balena terminal), then onboard as
**data-only** hotspot with `helium-wallet hotspots add`.

---

## 6. Entrypoint contract (per service)

Each `entrypoint.sh` (POSIX sh, no Python dependency):

1. If service optional and `*_ENABLED != true` → log one line, `exec sleep infinity`.
2. Export defaults for every `$VAR` used in the TOML template (required because
   the components' substitution leaves unset `$VARS` as literals).
3. Derive `GATEWAY_ID` from `/sys/class/net/eth0/address` (`FFFE` midfix) when unset.
4. Assemble the `-c` file list (template + region/channels files for the
   selected `CHANNEL_PLAN`; write TLS PEM env contents to files).
5. Validate the few high-risk inputs (chipset/model known, plan exists for
   chipset) and fail fast with a clear log message — the resin template's
   "wrong reset pin → cryptic concentrator error" lesson.
6. `exec` the daemon (proper PID 1 signal handling; `restart: always` +
   Balena supervisor replace the template's Python respawn loop).

---

## 7. Feature-parity matrix vs ChirpStack Gateway OS

| Gateway OS feature | This design |
|---|---|
| Concentratord, 3 chipsets, all shields/regions | ✅ same binaries, env-var selected |
| MQTT forwarder (TLS, filters, per-region topic) | ✅ |
| UDP forwarder (multiple servers, filters) | ✅ |
| Gateway mesh (border/relay, proxy chain) | ✅ |
| Full image: ChirpStack NS + Mosquitto + Redis (sqlite) | ➖ out of scope — gateway-only design, always forwards to a remote NS |
| Helium IoT network support (not in Gateway OS) | ✅ addition: `helium-gateway` (gateway-rs) fed by the UDP forwarder |
| Gateway ID from MAC (`fffe` midfix) | ✅ same derivation |
| Channel-plan changes also update topic prefix | ✅ single `CHANNEL_PLAN` variable drives both |
| Dual concentrator slots (RAK dual-slot boards) | ➖ not initially; add a second concentratord service when needed |
| LuCI web UI | ➖ replaced by Balena dashboard variables |
| WiFi AP fallback / network config | ➖ balenaOS; optional `wifi-connect` container later |
| watchcat / collectd / statistics | ➖ Balena supervisor + dashboard metrics; UDP forwarder Prometheus endpoint optional |
| GPS→NTP (gpsd refclock) | ➖ out of scope initially; balenaOS uses chrony/NTP |
| Concentrator firmware upgrade buttons (dfu-util) | ➖ manual via Balena terminal if ever needed |
| ChirpStack REST API, Node-RED (packaged, not shipped) | ➖ out of scope |

---

## 8. Implementation phases

1. **Phase 1 — core gateway (base image parity):**
   compose + concentratord + mqtt-forwarder images, entrypoints, EU868 + US915
   validated on the MNTD. Blackspot (decision 3: Pi 4 + RAK2287), README with
   variable tables.
2. **Phase 1b — optional forwarders:** udp-forwarder, gateway-mesh and
   helium-gateway services; border/relay chain validated between two devices;
   Helium chain validated on a converted hotspot (MNTD/RAK V2 and/or SenseCAP
   M1 — ECC608 identity preserved, i2c address/slot confirmed per model).
3. **Phase 2 — niceties:** `wifi-connect`, second concentratord slot, Prometheus
   metrics.

### Deployment / validation roadmap

| # | Device | Chipset | `CONC_MODEL` | Notes |
|---|---|---|---|---|
| 1 | MNTD. Blackspot (RAK V2) | SX1302 | `rak_2287` | decision 3 primary validation; ECC608 Helium identity |
| 2 | Seeed SenseCAP M1 | SX1302/03 | `seeed_wm1302` | second converted hotspot; ECC608 |
| 3 | DIY: RPi 3B+ + RAK831 | SX1301 | `rak_2245` (no dedicated RAK831 profile; same SX1301 front-end — verify reset pin, override via `CONC_RESET_*`) | `GATEWAY_ID` from MAC (SX1301 has no chip EUI) |
| 4 | DIY: RPi 3B+ + IMST iC880A | SX1301 | `imst_ic880a` | reset pin depends on backplane wiring (`CONC_RESET_*`) |

Fleet/architecture note: the RPi 3B+ units make `armv7hf` (device type
`raspberrypi3`) the common denominator — Pi 4-based hotspots can join an
`armv7hf` fleet, so all four deployments can share **one fleet** using the
`armv7-unknown-linux-musleabihf` artifacts. Alternatively run two fleets
(aarch64 for the Pi 4 hotspots, armv7hf for the 3B+ units) at the cost of
managing two.

---

## 9. Risks / notes

- **Artifact availability:** the build depends on GitHub release assets
  remaining downloadable (D8). Checksums pin content; availability is
  mitigated by mirroring the pinned artifacts — gateway-rs first, since its
  maintenance is expected to stop — as release assets of this repository and
  flipping the Dockerfile base-URL ARG to the mirror if an upstream asset
  disappears.
- **USB vs SPI shields:** USB concentrators (`/dev/ttyACM0`) need `UDEV=on` in
  the concentratord image and privileged mode to enumerate reliably.
- **Env-var substitution pitfall:** unset `$VARS` stay as literal text in the
  TOML; every placeholder must get an entrypoint default. A startup log line
  printing the rendered config (secrets masked) makes this debuggable.
- **`/dev/ttyAMA0` GNSS on Pi 3/4** needs the Bluetooth UART overlay change via
  `BALENA_HOST_CONFIG_dtoverlay`, same class of fix as the resin template's
  `pi3-miniuart-bt` note.
- **Helium identity on converted hotspots:** on MNTD/RAK V2 the identity lives
  in the ECC608 and survives flashing balenaOS — gateway-rs reads it directly
  (D7) and the unit remains an onboarded hotspot; nothing to back up. Keypair
  backup only matters for **file-based** identities (no secure element): there,
  losing `keypair.bin` means losing the onboarded hotspot — hence the named
  volume, and document backing up the file after onboarding. Verify the ECC
  i2c address/slot once per hotspot model, and never run the stock miner
  firmware in parallel with this instance.
- **`HELIUM_SWARM_KEY` is a private key in a Balena variable:** it is visible
  to anyone with dashboard access to the fleet/device and must never be logged.
  Set it as a *device* variable (not fleet-wide — each identity is per-device),
  and prefer the generated-key path when there is no existing identity to
  migrate. Since the swarm key overwrites the keypair file on every start, a
  device without a secure element that has both a volume-persisted key and
  `HELIUM_SWARM_KEY` set will always assume the supplied identity — remove the
  variable to fall back. When a secure element is detected it outranks both
  (D7 priority).

---

## 10. Open decisions for review

1. ~~**Binaries: build from submodules vs download GitHub release artifacts?**~~
   **Decided (D8): pinned release artifacts.** The submodules are reference
   material, not build source; no patching is intended; ChirpStack upstream is
   actively maintained. gateway-rs artifacts are mirrored in this repo's
   releases against upstream abandonment. Analysis in
   [Appendix A](#appendix-a-build-from-submodules-vs-release-artifacts).
2. ~~**Env-var prefixes?**~~ **Decided: per-service prefixes
   `CONC_/MQTT_/UDP_/MESH_/HELIUM_`**, with unprefixed globals `GATEWAY_ID` /
   `CHANNEL_PLAN` and `GW_*` reserved as gateway-rs's native namespace.
   Analysis in
   [Appendix B](#appendix-b-env-var-prefix-scheme-conc_mqtt_udp_mesh_helium_).
3. ~~**Initial hardware validation target?**~~ **Decided: MNTD. Blackspot
   (RAK Hotspot Miner V2)** — Raspberry Pi 4 + RAK2287 (SX1302),
   `CONC_CHIPSET=sx1302`, `CONC_MODEL=rak_2287`. Validates the ChirpStack
   chain, the hotspot conversion path, and the ECC608 Helium identity (D7) on
   one device.
4. ~~**Dual-slot support?**~~ **Decided: not in the design.** A single
   concentratord instance only; a second slot (e.g. EU868 + ISM2400 mesh)
   remains a possible later addition (see D2), out of scope for now.

---

## Appendix A: build from submodules vs release artifacts

All five components (four ChirpStack + gateway-rs) are Rust projects whose
upstreams publish per-target release tarballs on GitHub. Both approaches yield
the same statically linked musl binaries; the difference is who compiles them
and when.

### Option 1 — build from submodules (not chosen)

The Dockerfile build stage compiles the pinned submodule with the pinned
toolchain (`rust-toolchain.toml`, currently 1.89.0) and the target's musl
triple; concentratord additionally compiles the vendored Semtech HAL C code
(needs `libclang`/bindgen in the build stage).

Pros:

- **Matches the intent of this repo** — the submodules were added precisely so
  the build does not depend on external availability at build time (GitHub
  release assets can be deleted, re-tagged, or rate-limited; a vendored
  submodule cannot disappear).
- **Exact pinning and auditability:** the built binary corresponds to a commit
  visible in `git submodule status`; upgrades are explicit submodule bumps
  with reviewable diffs.
- **Patchability:** local fixes (a new `CONC_MODEL` vendor profile, a config
  tweak, the mesh `root_key` naming mismatch, …) are a patch in the submodule,
  not a fork of upstream's release pipeline.
- **Uniformity:** one Dockerfile shape for all five services, including any
  future component that has no release artifacts.

Cons:

- **First-build time.** Five Rust workspaces on the balenaCloud builders:
  roughly 10–20 min for concentratord (workspace + C HAL) and 5–10 min per
  forwarder — expect 30–60 min cold per device type. Docker layer caching
  makes rebuilds cheap as long as the submodule and Dockerfile layers are
  unchanged, but the balena builder cache is per-fleet and occasionally cold.
- **Toolchain drift risk:** each upstream pins its own Rust version; the build
  stages must follow the submodules' `rust-toolchain.toml` when bumping.
- **Cross-compile plumbing:** the build stage must select the right musl
  triple per `%%BALENA_MACHINE_NAME%%` (see table below) and install the
  matching linker.

### Option 2 — download upstream release artifacts (chosen — D8)

The Dockerfile fetches the versioned tarball for the target triple, verifies a
pinned SHA-256, and unpacks the binary. Build time drops to seconds.

Pros: near-instant builds; binaries identical to what Gateway OS ships; no
Rust toolchain in the build at all.

Cons: reintroduces the external dependency the submodules were meant to
remove; pinning is by version string + checksum rather than by commit; local
patches are impossible; each component's release naming/triple layout must be
mapped per architecture; upstream provides no artifact for a future component
or an unusual target (e.g. Pi Zero needs the `armv5te` variant).

### Architecture mapping (needed by both options)

| Balena machine | Arch | Rust musl triple |
|---|---|---|
| `raspberry-pi` (Zero/1) | armv6 (hard-float) | `armv5te-unknown-linux-musleabi` (soft-float, runs on armv6; upstream's choice) |
| `raspberry-pi2`, `raspberrypi3` (32-bit) | armv7hf | `armv7-unknown-linux-musleabihf` |
| `raspberrypi3-64`, `raspberrypi4-64`, `raspberrypi5` | aarch64 | `aarch64-unknown-linux-musl` |

Note: Pi Zero/1 is the worst case for option 1 (slow native/emulated armv6
builds) and mildly awkward for option 2 (armv5te artifact naming). If Pi
Zero/1 support is not required, dropping it simplifies both options.

### Decision (D8): pinned release artifacts

Option 2 is chosen because the premises favouring option 1 do not apply here:
the submodules were added as **reference material** (design inspection, static
config files), not as build source; **no local patching is intended**; and
ChirpStack upstream is actively maintained, so tracking its releases is the
natural cadence. Concretely:

1. Dockerfiles download the per-target musl tarball pinned by **version +
   SHA-256** (the checksum makes the build reproducible and tamper-evident;
   a silent re-tag upstream fails the build instead of changing the binary).
2. Static TOML examples (regions/channels/mappings/settings) are COPYed from
   the submodules — they need no compilation, so the submodules still
   contribute directly to the images.
3. **Abandonment hedge:** gateway-rs is expected to stop being maintained.
   Its pinned artifacts are mirrored as release assets of this repository
   (optionally all five components), and a Dockerfile ARG switches the
   download base URL to the mirror if an upstream asset disappears. This
   preserves availability without taking on the build-from-source machinery.
4. Building from the submodules remains possible as a manual fallback
   (option 1 above documents what it takes) but is not part of the design.

---

## Appendix B: env-var prefix scheme (`CONC_/MQTT_/UDP_/MESH_/HELIUM_`)

### The scheme

- **One prefix per service**, mirroring the Gateway OS LuCI menu split:
  `CONC_*` (concentratord), `MQTT_*` (mqtt-forwarder), `UDP_*`
  (udp-forwarder), `MESH_*` (gateway-mesh), `HELIUM_*` (helium-gateway
  orchestration).
- **Deliberately unprefixed globals** for the two values that must be shared
  by design: `GATEWAY_ID` and `CHANNEL_PLAN`.
- **`GW_*` is reserved for gateway-rs** — it is that daemon's *native*
  override namespace (`GW_REGION`, `GW_LISTEN`, `GW_KEYPAIR`, …), passed
  through untouched. `HELIUM_*` marks the variables our entrypoint acts on
  (enable gate, ECC probe, swarm key), so "consumed by us" vs "consumed by
  gateway-rs" is visible in the name.
- Within a prefix, names follow the component's own TOML setting names
  (`MQTT_TOPIC_PREFIX` → `[mqtt] topic_prefix`), so the upstream documentation
  maps 1:1. Indexed upstream slots use the resin-style `_n` suffix
  (`UDP_SERVER_ADDRESS_0`).
- Conventions: booleans are the literal strings `true`/`false` (resin
  convention), lists are comma-separated, secrets are never logged.

### Why per-service prefixes beat flat resin-style `GW_*`

1. **Collision with gateway-rs is guaranteed, not hypothetical.** gateway-rs
   already owns `GW_*`. A flat scheme would either clash outright or force
   awkward renames: `GW_REGION` would mean "Helium region" to gateway-rs while
   a reader would expect "LoRa channel plan".
2. **Balena delivers fleet/device variables to every service.** All containers
   see the same environment, so the namespace is genuinely shared. The resin
   template could use flat `GW_*` because it had exactly one container; this
   design has six.
3. **Ambiguity in a flat scheme grows with every service.** `GW_SERVER` —
   MQTT broker, UDP upstream, or Helium router? Prefixes answer that question
   in the variable name itself.
4. **The Balena dashboard sorts variables alphabetically**, so prefixes
   cluster each service's settings into a visually contiguous block — the
   closest thing the dashboard offers to the LuCI per-service pages.
5. **Optional tighter scoping comes free.** Balena also supports per-service
   "service variables"; prefixed names map 1:1 onto them. Setting e.g.
   `MQTT_PASSWORD` as a service variable on `mqtt-forwarder` means only that
   container sees the secret and only that container restarts when it
   changes. A flat namespace cannot express this mapping cleanly.
6. **Restart blast radius.** The supervisor restarts services whose
   environment changed. Device-wide variables restart everything regardless
   of naming, but the prefix scheme plus service variables (point 5) lets an
   operator confine a change to the one affected service.

### Cost

Slightly longer names than resin's (`CONC_ANTENNA_GAIN` vs `GW_ANTENNA_GAIN`),
and operators migrating from the resin template must rename their variables
once (a short mapping table in the README covers this: `GW_ID` → `GATEWAY_ID`,
`GW_ANTENNA_GAIN` → `CONC_ANTENNA_GAIN`, `SERVER_n_*` → `UDP_SERVER_*_n`, …).
