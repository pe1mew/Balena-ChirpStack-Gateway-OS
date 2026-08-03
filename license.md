# License Information

## This repository: MIT

The original work in this repository — Dockerfiles, entrypoint scripts,
configuration templates, the compose file, and all documentation under
`design/` — is licensed under the **MIT License**, Copyright (c) 2026
Remko Welling (PE1MEW). See [LICENSE](LICENSE) for the full text.

## Third-party components

This project downloads (or, for the UDP forwarder, compiles) the following
components at image build time. Each keeps its own license; the submodules in
this repository contain the respective upstream license texts.

| Component | Author / copyright | License | Role |
|---|---|---|---|
| [chirpstack-concentratord](https://github.com/chirpstack/chirpstack-concentratord) | Orne Brocaar | MIT | concentrator HAL daemon (binaries + region/channel config files) |
| [chirpstack-mqtt-forwarder](https://github.com/chirpstack/chirpstack-mqtt-forwarder) | Orne Brocaar | MIT | MQTT forwarder binary |
| [chirpstack-udp-forwarder](https://github.com/chirpstack/chirpstack-udp-forwarder) | Orne Brocaar | MIT | UDP forwarder (compiled from the submodule) |
| [chirpstack-gateway-mesh](https://github.com/chirpstack/chirpstack-gateway-mesh) | Orne Brocaar | MIT | mesh border/relay binary + region mappings |
| [gateway-rs](https://github.com/helium/gateway-rs) | Helium Systems, Inc. | Apache-2.0 | Helium gateway binary + default settings |
| Semtech SX130x HAL | Semtech Corporation | Revised BSD | embedded inside the concentratord binaries |
| [ChirpStack Gateway OS](https://github.com/chirpstack/chirpstack-gateway-os) | Orne Brocaar | MIT | reference only (feature parity target); nothing from it ships in the images |
| [ttn-resin-gateway-rpi](https://github.com/jpmeijers/ttn-resin-gateway-rpi) | JP Meijers and contributors | no license file published | **inspiration only** — the env-var-driven balena gateway pattern; no code from it is included in this repository |

## Notes

- The MIT and Apache-2.0 licensed components are redistributed unmodified as
  binaries inside the built container images; their copyright notices remain
  in the submodules and in the upstream release archives.
- `ttn-resin-gateway-rpi` publishes no license, so no code, scripts, or
  files from it were copied. This repository reimplements the *concept*
  (environment-variable-driven gateway configuration on balena) from scratch
  on the ChirpStack toolchain, with credit to JP Meijers in the
  [README](README.md#acknowledgements).
