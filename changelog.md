# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

---

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
