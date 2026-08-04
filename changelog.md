# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

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
  DevAddr/JoinEUI filters, `concentratord` or `mesh` backend. The daemon
  natively supports multiple upstream connections (`[[ttn]]` array; uplinks
  fan out, downlinks share the JIT queue); the balena template exposes one
  connection via `TTN_*` variables.

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
