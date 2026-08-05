# Balena ChirpStack Gateway OS

A multi-container [balenaCloud](https://www.balena.io/) application that turns
a Raspberry Pi based LoRaWAN® gateway — including converted Helium hotspots —
into the equivalent of [ChirpStack Gateway OS](https://www.chirpstack.io/docs/chirpstack-gateway-os/),
configured entirely through **environment variables** in the balena dashboard.

One device can serve multiple LoRaWAN networks at the same time. Validated on
real hardware: a Seeed SenseCAP M1 concurrently forwarding to a private
ChirpStack instance (MQTT), The Things Network (Semtech UDP), and the Helium
IoT network (gateway-rs) — the latter with the hotspot's original ECC608
identity preserved through the conversion.

## Services

| Service | Upstream project | Default |
|---|---|---|
| `concentratord` | [chirpstack-concentratord](https://github.com/chirpstack/chirpstack-concentratord) — SX1301/SX1302/2G4 HAL daemon | enabled |
| `mqtt-forwarder` | [chirpstack-mqtt-forwarder](https://github.com/chirpstack/chirpstack-mqtt-forwarder) — events → ChirpStack MQTT broker | enabled |
| `udp-forwarder` | [chirpstack-udp-forwarder](https://github.com/chirpstack/chirpstack-udp-forwarder) — events → Semtech-UDP server(s) (TTN, Helium, …) | disabled |
| `ttn-forwarder` | [chirpstack-ttn-mqtt-forwarder](https://github.com/pe1mew/chirpstack-ttn-mqtt-forwarder) — events → TTN protobuf-MQTT ("packet broker"; The Things Gateway replacement) | disabled |
| `gateway-mesh` | [chirpstack-gateway-mesh](https://github.com/chirpstack/chirpstack-gateway-mesh) — LoRa mesh border/relay | disabled |
| `helium-gateway` | [helium/gateway-rs](https://github.com/helium/gateway-rs) — Helium IoT network | disabled |

Binaries are downloaded at image build from the upstream releases, pinned by
version and SHA-256. The submodules in this repository serve as reference and
as the source of static configuration files; the UDP forwarder (upstream
publishes no binaries for it) and the TTN forwarder (developed in this
project) are compiled from their submodules.

## Supported hardware

**Supported** is defined by chirpstack-concentratord: any Raspberry Pi that
balenaOS runs on, with any concentrator model in concentratord's vendor list
(iC880A, RAK2245/2246/2247/2287/5146, Seeed WM1302, Semtech CoreCell,
2.4 GHz variants, and more — set via `CONC_MODEL`). The following
combinations were **verified** on real hardware with this stack:

| Device | Board | Concentrator | `CONC_MODEL` | Notes |
|---|---|---|---|---|
| MNTD./RAK Hotspot Miner V2 | Raspberry Pi 4 | RAK2287 (SX1302) | `rak_2287` | converted Helium hotspot |
| Seeed SenseCAP M1 | Raspberry Pi 4 | WM1302/03 (SX1302/03) | `seeed_wm1302` | converted Helium hotspot |
| DIY: RAK831 | Raspberry Pi 3B+ | RAK831 (SX1301) | `rak_2245` | no dedicated RAK831 profile — the `rak_2245` profile matches (same SX1301 front-end); reset default GPIO17 |
| DIY: IMST iC880A | Raspberry Pi 3B+ | iC880A (SX1301) | `imst_ic880a` | set `CONC_RESET_PIN` to match the backplane wiring (e.g. `17` for pin-11/ch2i style, `25` for Gonzalo Casas/Coredump) |

On converted hotspots the Helium identity in the ECC608 secure element
survives the conversion and is used by gateway-rs automatically. On SX1301
boards (RAK831, iC880A) the gateway EUI is derived from the Pi's MAC address
(`xxxxxxFFFExxxxxx`) — the same derivation the classic resin-era stack used,
so existing registrations keep their EUI.

## Getting started

- [design/howto.md](design/howto.md) — step-by-step deployment guide:
  flashing, variables, ChirpStack registration, optional services,
  troubleshooting.
- [design/environmentVariables.md](design/environmentVariables.md) — the
  complete environment-variable reference, with the minimum set marked.
- [design/design.md](design/design.md) — the full design: architecture and
  decisions.

The short version: push this repository to a balena fleet, flash a device,
set `CONC_MODEL` and `MQTT_SERVER`, done. Every setting is a dashboard
variable; changing one restarts only the affected service.

## Acknowledgements

This project stands on the work of others, and that deserves to be said
clearly:

- **JP Meijers**, author of
  [ttn-resin-gateway-rpi](https://github.com/jpmeijers/ttn-resin-gateway-rpi) —
  the direct inspiration for this repository. His balena/resin.io gateway
  concept — a container that configures a LoRaWAN gateway from nothing but
  dashboard environment variables — has been running for **more than nine
  years** on the gateways of **Stichting IoT-Apeldoorn e.o.**, and it still
  works today. This repository is that same idea, rebuilt on the ChirpStack
  toolchain. Thank you, JP.
- **Orne Brocaar**, author of [ChirpStack](https://www.chirpstack.io/) and
  all four ChirpStack gateway components used here (MIT licensed). The clean
  ZMQ architecture and the native environment-variable substitution in his
  configuration loaders are what make this project's approach possible.
- **Helium / Nova Labs** for [gateway-rs](https://github.com/helium/gateway-rs)
  (Apache-2.0), whose native `GW_*` environment overrides and ECC608 support
  fit this design like a glove.
- **Semtech** for the SX130x HAL libraries embedded in the concentratord
  binaries.
- **RAKwireless** and **Seeed Studio** for well-documented gateway hardware.

## About this project: AI-assisted development

This project was made exclusively with the help of **Claude** (Anthropic),
under my supervision. The goal is to practice and experiment with
programming, leveraging AI tools such as Claude, and to learn to work with
these tools. Please note that, while AI assistance has accelerated
development, I cannot guarantee the originality or accuracy of all code
segments, as the sources used by large language models are not always
transparent or verifiable. The results and information presented here have
not been exhaustively validated. As such, I advise caution: **do not rely on
this code or its output for critical applications without independent
verification.** The disclaimer below applies in full.

## Disclaimer

This project is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.

## License

The code in this repository (Dockerfiles, entrypoint scripts, configuration
templates, documentation) is MIT licensed — see [LICENSE](LICENSE). The
upstream components keep their own licenses — see [license.md](license.md)
for the complete overview.
