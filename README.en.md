# AnyHack 🔧

A root multitool for the **Xiaomi 14T** (HyperOS + KernelSU). Three tabs, zero bloat, everything live.

## Features

**⚡ Dashboard**
- live monitoring every 1.5s (own interval via the gear: 0.5 / 1 / custom)
- per-core CPU (little / medium / big) + governor, Mali-G615 GPU: frequency and load
- **battery**: while charging — voltage, amperage and watts below; while discharging — discharge power in watts
- **CPU profiles**: `Performance` · `Balanced` · `Economy` · `Economy+` — cap core frequencies with one tap, remembered between launches
- RAM, `/data` storage, CPU and GPU temperatures

**🖥 Display**
- refresh rate lock: Auto / 60 / 90 / 120 / 144 Hz + **Custom Hz** (any number 30…165)
- keys are written to both `system` and `secure` (HyperOS reads both), with a "applied / not applied" check after every write

**📡 Other**
- IR remote: import `.ir` files from Flipper Zero, remotes shown as square tiles, "+" on top
- tapping a tile opens the remote's commands; after import the control screen opens automatically
- protocols: NEC, NECext, NEC42, NEC42ext, Samsung32, SIRC/15/20, RC5, RC6, Kaseikyo, RCA + raw
- **build.prop** viewer with search and copy

**Root**
- startup screen: without root you get "Retry" and "Exit" buttons
- root via the KernelSU API (`prctl` + `supercall` ioctl) with a strict verification and automatic `su` fallback

## build & release

Every push to `main` triggers GitHub Actions, which builds and uploads
`AnyHack-arm64-R<run>.apk` to Releases.

## install

```bash
gh release download -R internetov-coder/AnyHack --pattern "*.apk"
adb install -r AnyHack-arm64-R*.apk
```

## stack

Flutter (Material 3) + Kotlin (`ConsumerIrManager`, SAF picker) + root shell via `su`/KernelSU API.
