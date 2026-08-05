# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

**Fixed**
- ttn-forwarder updated to chirpstack-ttn-mqtt-forwarder **v0.2.1**: rejects
  an all-zero gateway ID from the backend (keeps retrying instead of
  adopting it) — the forwarder-side defense for the zero-ID race below.
  Verified on hardware: normal-path ID acquisition and TTN connection
  unaffected; rejection path never triggered with the startup gates active.
- Zero-gateway-ID boot race on `MQTT_BACKEND=mesh` gateways (stack-level
  mitigation): gateway-mesh now waits for concentratord's command API before
  starting (so its first gateway-ID fetch succeeds and the proxy never serves
  an all-zero ID), and the mqtt-/ttn-forwarders wait for the mesh proxy
  before reading the ID. Verified with three consecutive restart trials on a
  live border gateway (correct EUI on the first topic subscribe every time,
  zero occurrences of the all-zero ID); rolled out to all fleets.
  Root-cause fixes remain proposed upstream (gateway-mesh should not answer
  before the ID is known and should re-fetch after backend reconnect;
  forwarders should reject all-zero IDs).
- concentratord entrypoint now **refuses `CONC_RESET_PIN`/`CONC_POWER_EN_PIN`
  values 7–11** on the default GPIO chip: those are the SPI0 pads, and
  claiming one re-muxes it away from the SPI controller, silently breaking
  the concentrator bus until the device reboots. The error message explains
  the usual cause — physical header pin numbers instead of GPIO offsets
  (physical pin 11 = GPIO17, pin 22 = GPIO25; full translation table in
  design/environmentVariables.md). `CONC_GPIO_FORCE=true` overrides for
  boards that genuinely repurpose an SPI pad. Diagnosed on a live gateway
  where `CONC_RESET_PIN=11` had hijacked the SPI clock line.
- MNTD. Blackspot / RAK Hotspot Miner V2: the SX1302 reset is on **GPIO25**
  (Helium `hm-pyhelper` variant `rak-fl1`), not the `rak_2287` profile
  default GPIO17 — set `CONC_RESET_PIN=25`. Without it the chip is never
  reset: units wedge with `chip version is 0x05` / `Failed to set SX1250_0
  in STANDBY_RC` after any service restart (recoverable only by physical
  power cycle), and runs that do come up receive only corrupt frames
  (`wrong coding rate (0)` flood, `rx_received_ok` = 0). Verified on
  hardware: with `CONC_MODEL=rak_2287` + `CONC_RESET_PIN=25` starts,
  restarts, and reception (uplinks decoding, zero garbage triggers) are all
  clean. **This retracts the earlier "unit's RAK2287 module found
  defective" conclusion below — that module was a victim of the same
  missing reset, and the "marginal SPI" troubleshooting guidance derived
  from it (reseating, core-clock lock, module replacement) addressed
  symptoms, not the cause.** README/howto/variable docs updated
  accordingly. Reported upstream:
  [chirpstack-concentratord#286](https://github.com/chirpstack/chirpstack-concentratord/issues/286).

**Validated on hardware**
- Gateway mesh (border/relay): SenseCAP M1 as border gateway
  (`MESH_BORDER_GATEWAY=true`, `MQTT_BACKEND=mesh`) receiving and unwrapping
  MIC-valid relayed uplinks (hop count 1) from a **RAK7269v2 running stock
  ChirpStack Gateway OS** as relay — proving cross-stack mesh
  interoperability between this Balena stack and Gateway OS gateways
  (relevant for mixed fleets during migration).
- iC880A on Pi 3B+ (`imst_ic880a`, `CONC_RESET_PIN=17` for pin-11 backplane
  wiring) forwarding to ChirpStack; RAK831 on Pi 3B+ (`rak_2245`) forwarding
  to TTN via the ttn-forwarder.

**Added**
- `ttn-forwarder` multi-connection support (chirpstack-ttn-mqtt-forwarder
  v0.2.0, `[[ttn]]` array of tables): up to 4 simultaneous upstream
  connections via indexed `TTN_GATEWAY_ID_n` / `TTN_GATEWAY_KEY_n` /
  `TTN_SERVER_n` slots; unsuffixed variables remain slot-0 aliases
  (backwards compatible with single-connection deployments).
- `ttn-forwarder` service
  ([chirpstack-ttn-mqtt-forwarder](https://github.com/pe1mew/chirpstack-ttn-mqtt-forwarder)
  v0.2.0, compiled from submodule): bridges concentratord to the TTN
  protobuf-MQTT gateway protocol (The Things Stack Gateway Server MQTT
  frontend / "packet broker", default `eu1.cloud.thethings.network:1881`, or
  a self-hosted gateway-connector-bridge). Drop-in replacement for gateways
  commissioned with the mp_pkt_fwd + ttn-gateway-connector stack — existing
  gateway registrations (ID + key) keep working. Disabled by default
  (`TTN_ENABLED=true` to activate); optional TLS (port 8881), CRC and
  DevAddr/JoinEUI filters, `concentratord` or `mesh` backend. Supports
  multiple simultaneous upstream connections via indexed slots
  (`TTN_GATEWAY_ID_0..3` etc., resin-template pattern; unsuffixed `TTN_*`
  variables alias slot 0) — uplinks fan out to every connection, downlinks
  share the JIT queue first come, first served.

## [1.0.0] — 2026-08-03

First release: feature parity with the ChirpStack Gateway OS "base" image on
balenaCloud, plus Helium support.

**Added**
- `concentratord` service: all three chipset binaries (SX1301/SX1302/2G4,
  upstream v4.7.1), env-var driven model/channel-plan selection, gateway-ID
  precedence (explicit `GATEWAY_ID` → SX1302 chip EUI → MAC-derived for
  SX1301 via the supervisor API).
- `mqtt-forwarder` service (upstream v4.6.0): TLS, filters, region topic
  prefix from `CHANNEL_PLAN`, concentratord or mesh-proxy backend.
- `udp-forwarder` service (v4.3.0, compiled from submodule — upstream
  publishes no binaries): resin-style indexed `UDP_SERVER_ADDRESS_n` /
  `UDP_SERVER_PORT_n` / `UDP_SERVER_ENABLED_n` upstream slots.
- `gateway-mesh` service (upstream v4.1.3): border/relay roles, region
  mappings, proxy API for the border-gateway chain.
- `helium-gateway` service (gateway-rs v1.3.0): identity priority ECC608
  secure element → supplied swarm key → generated keypair; native `GW_*`
  pass-through; `GW_POC_DISABLE` recommended (beaconing sunset).
- Design document (`design/design.md`) and deployment guide
  (`design/howto.md`) with hardware-validated troubleshooting.

**Validated on hardware**
- Seeed SenseCAP M1: concurrent ChirpStack (MQTT), TTN (UDP) and Helium
  (ECC608 identity preserved through the balenaOS conversion).
- MNTD. Blackspot: stack validated; unit's RAK2287 module found defective
  (SPI read corruption) — diagnosis procedure documented in the howto.
  *(Retracted — the module was fine; the symptom was the missing GPIO25
  reset. See the Fixed entry above and
  [chirpstack-concentratord#286](https://github.com/chirpstack/chirpstack-concentratord/issues/286).)*
