# HOWTO: deploy the Balena ChirpStack Gateway

Step-by-step reproduction guide for the phase-1 stack (concentratord +
mqtt-forwarder), following the deployment roadmap of
[design.md](design.md) — first target: **MNTD. Blackspot (RAK Hotspot Miner
V2)**. Later deployments (SenseCAP M1, DIY SX1301 builds) reuse the same steps
with different variables; see [section 9](#9-other-deployments).

## 1. Prerequisites

- A [balenaCloud](https://dashboard.balena-cloud.com/) account and an existing
  **fleet** for this purpose. Note the fleet's device type / architecture:
  the images default to **armv7hf** artifacts (device type `raspberrypi3`).
  Pi 4-based devices can join an armv7hf fleet. For an **aarch64** fleet see
  [section 8](#8-building-for-an-aarch64-fleet).
- The [balena CLI](https://github.com/balena-io/balena-cli) logged in
  (`balena login`).
- A reachable **ChirpStack** instance and its MQTT broker (address, port,
  credentials/TLS as applicable).
- Hardware: MNTD. Blackspot, a microSD card (the unit's own card can be
  reused — this **erases the stock miner firmware**), Ethernet or WiFi.

## 2. Get the source

Only the `chirpstack-concentratord` submodule is needed by the build (static
config examples); do **not** recurse into all submodules — the
`chirpstack-gateway-os` submodule pulls in the entire OpenWrt tree.

```bash
git clone https://github.com/pe1mew/Balena-ChirpStack-Gateway-OS.git
```

```bash
cd Balena-ChirpStack-Gateway-OS && git submodule update --init chirpstack-concentratord
```

## 3. Push the release to your fleet

From the repository root (replace `myfleet` with your fleet name):

```bash
balena push myfleet
```

The builders fetch the version+SHA-256-pinned ChirpStack binaries (design
decision D8) — the build takes a few minutes, no Rust compilation involved.

## 4. Prepare the MNTD. Blackspot

1. Open the enclosure and remove the microSD card.
2. In the balena dashboard: **Add device** on your fleet, pick the matching
   Raspberry Pi 4 device type (compatible with an armv7hf fleet), configure
   WiFi credentials if no Ethernet, download the balenaOS image.
3. Flash the image to the microSD card (balena Etcher or `balena os` CLI).
4. Reinsert the card, connect network, power up. The device appears on the
   dashboard after a few minutes and downloads the release.

The unit's Helium identity in the ECC608 is untouched by this step (design
D7); it is not used by the phase-1 stack.

## 5. Configure host and device variables

### Fleet or device configuration (dashboard → Device/Fleet configuration)

| Config variable | Value | Why |
|---|---|---|
| `BALENA_HOST_CONFIG_dtparam` | `"i2c_arm=on","spi=on"` | enable the SPI bus for the RAK2287 (and i2c) |

### Device variables (dashboard → Device variables)

Minimum set for the Blackspot on EU868 forwarding to your ChirpStack:

| Variable | Value | Notes |
|---|---|---|
| `CONC_MODEL` | `rak_2287` | **required** |
| `MQTT_SERVER` | e.g. `ssl://chirpstack.example.net:8883` or `tcp://…:1883` | **required** |
| `MQTT_USERNAME` / `MQTT_PASSWORD` | as needed | only if the broker requires auth |
| `MQTT_CA_CERT` | PEM content | only for TLS with a private CA |
| `CONC_MODEL_FLAGS` | `GPS` | optional: RAK2287 variant with GNSS |
| `CHANNEL_PLAN` | `eu868` | default is already `eu868`; set `us915_0` etc. for other plans |
| `CONC_ANTENNA_GAIN` | e.g. `2` | dBi of the fitted antenna |

Defaults that normally need no change: `CONC_CHIPSET=sx1302`,
`MQTT_ENABLED=true`, `MQTT_TOPIC_PREFIX=<CHANNEL_PLAN>`, `GATEWAY_ID` unset
(the SX1302 chip EUI is used — stable across SD-card reflashes).

Changing any variable restarts the affected containers and re-renders the
configuration (resin-template pattern).

## 6. Register the gateway in ChirpStack

1. Read the gateway EUI from the logs: dashboard → device → Logs, look for
   the concentratord line `Gateway ID retrieved, gateway_id: …` (or run
   `balena logs <device> --service concentratord`).
2. In the ChirpStack console: **Gateways → Add gateway**, paste the EUI,
   pick the matching region/channel plan.

## 7. Verify

Expected in the logs:

- `concentratord`: `[entrypoint] chipset=sx1302 model=rak_2287 …`, then
  concentrator init and `Gateway ID retrieved`.
- `mqtt-forwarder`: `[entrypoint] server=… topic_prefix=eu868 …`, then a
  successful MQTT connect.
- ChirpStack console: the gateway's *last seen* updates every stats interval
  (default 30 s).
- End-to-end: bring an OTAA test node in range and check its join request on
  the gateway's **LoRaWAN frames** tab.

Troubleshooting:

| Symptom | Likely cause |
|---|---|
| `failed to start the concentrator` | SPI not enabled (host config), wrong `CONC_MODEL`, or reset-pin mismatch (`CONC_RESET_CHIP`/`CONC_RESET_PIN` override) |
| literal `$VAR` text in an error | variable referenced in a template without an entrypoint default — report as bug |
| `no channels file for CHANNEL_PLAN=…` | typo in `CHANNEL_PLAN`, or plan not supported by the chipset (the error lists what is available) |
| MQTT connect errors | `MQTT_SERVER` scheme/port, credentials, or missing `MQTT_CA_CERT` |
| gateway never *seen* in ChirpStack | EUI mismatch (re-check logs) or wrong region topic prefix vs ChirpStack region configuration |

## 8. Building for an aarch64 fleet

The Dockerfiles default to armv7hf artifacts. For an aarch64 fleet
(`raspberrypi4-64`, `raspberrypi5`), change the `ARG` defaults in
[concentratord/Dockerfile.template](../concentratord/Dockerfile.template) and
[mqtt-forwarder/Dockerfile.template](../mqtt-forwarder/Dockerfile.template):

| ARG | armv7hf (default) | arm64 |
|---|---|---|
| `ARTIFACT_ARCH` | `armv7hf` | `arm64` |
| `SHA256_SX1301` | `5acaaee6e4f88a2df97d4588e6364b3aed79792579738ccc255ce06083d3c4cb` | `f0fd5be4ab9aea2bfcf4adca3bf83958dcbc4dec1d3898edfb81b61540644a5f` |
| `SHA256_SX1302` | `9eb735a02712988a6fd13d30994554850282a3e0dcdd77b94c89377c9863906e` | `328faf7e6fe6fcc9f5a50f8368fd520807ac2939214c607593318e017e857345` |
| `SHA256_2G4` | `a5398e94acb2ba528de4172c1099dde0c983fba173ee2fb3e9b12c6605409a14` | `f6f4272d57cf70501c231613486d05f041c7f44d96b39e31a5b7a147c8d8f753` |
| `SHA256_MQTT_FWD` | `d8a9884eacc9c50a7e3d758975d7e99c6bb42257677c7bab7dd4b2d7cdb79a1b` | `8be1c4fd70a4fdd921d87a01daf1c4ac5d4b8fef8dc7db37334d922b6d9675cd` |

(Versions pinned: concentratord 4.7.1, mqtt-forwarder 4.6.0.)

## 9. Other deployments

Same procedure as sections 4–7; only hardware prep and variables differ.

| Deployment | Variables | Notes |
|---|---|---|
| Seeed SenseCAP M1 | `CONC_MODEL=seeed_wm1302` | Pi 4 + WM1302/03; SD card inside the enclosure |
| DIY RPi 3B+ + RAK831 | `CONC_CHIPSET=sx1301`, `CONC_MODEL=rak_2245`, optionally `GATEWAY_ID` | no RAK831 profile — the `rak_2245` profile matches the SX1301 front-end; verify the reset pin, override with `CONC_RESET_CHIP=/dev/gpiochip0` + `CONC_RESET_PIN=<line>` if needed. Without `GATEWAY_ID`, the EUI is derived from the host MAC (`xxxxxxFFFExxxxxx`) |
| DIY RPi 3B+ + IMST iC880A | `CONC_CHIPSET=sx1301`, `CONC_MODEL=imst_ic880a`, optionally `GATEWAY_ID` | reset pin depends on the backplane wiring — same `CONC_RESET_*` override |

Phase 1b (UDP forwarder, gateway mesh, Helium gateway-rs) will extend this
guide when implemented.
