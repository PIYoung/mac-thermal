# Mac Thermal

[한국어](README.md) · **English** · [日本語](README.ja.md) · [简体中文](README.zh-CN.md)

A free, open-source menu bar app for a quick look at your Mac's temperature and resource usage. Real measurements, with a little motion.

**Made with AI.** The code, UI, translations, and documentation were created with OpenAI Codex and refined through iterative user feedback.

![Mac Thermal overview panel](docs/images/mac-thermal-summary.png)

The real UI is rendered with synthetic example data. Glass effects vary with the macOS version.

## Features

- **In the menu bar:** CPU temperature and utilization, SSD read/write rates, and network upload/download rates.
- **Indicators with motion:** CPU rhythm bars or orbiting dots, network flow in each transfer direction, and an SSD tank showing used capacity with waves driven by I/O activity.
- **Details in one click:** Overview, memory pressure and swap, the top three processes by CPU and memory, SSD activity and capacity, and time since boot.
- **Your preferences:** Instantly switch between Korean, English, Japanese, and Simplified Chinese at the top of Settings. Adjust motion, intensity, and launch at login. Korean is the default language.
- **At home on macOS:** Light and dark appearance, Liquid Glass on macOS 26, Reduce Motion, and keyboard navigation.
- **Local only:** No accounts, ads, analytics, tracking, server uploads, administrator helper, or fan control.

## Install

Requires an **Apple Silicon Mac running macOS 14 or later**. Current releases are ARM64 only; Intel Macs are not supported.

1. [Download the latest DMG](https://github.com/PIYoung/mac-thermal/releases/latest/download/Mac-Thermal-v2.3.0-arm64.dmg).
2. Open it and drag **Mac Thermal.app** into **Applications**.
3. Launch the app and click its menu bar indicators. It does not show a Dock icon.

A ZIP is also available on the [release page](https://github.com/PIYoung/mac-thermal/releases/latest). There is no automatic updater; install new versions from Releases.

The current binary is **ad-hoc signed**, without Apple Developer ID signing or notarization. macOS Gatekeeper may block a downloaded copy. If it is blocked, build from source below instead of disabling security settings. You can verify downloaded files against the release's `SHA256SUMS`.

### Build and install from source

Requires Apple Silicon and **Xcode 26, or compatible Command Line Tools with the macOS 26 SDK**. The deployment target is macOS 14; earlier than macOS 26, the app uses a standard translucent panel.

```sh
git clone https://github.com/PIYoung/mac-thermal.git
cd mac-thermal
zsh scripts/install.sh --open
```

This builds locally, installs to `~/Applications/Mac Thermal.app`, and launches it. Omit `--open` to install without launching. No `sudo` is used. To build only, run `zsh build.sh`. The result is `build/Mac Thermal.app`.

## Use

Click the menu bar to open a fixed-size panel. The **Settings** icon at the top right toggles settings. Language, the selected tab, and motion preferences persist across launches. Manage automatic startup in **Settings → Launch at login**. First-launch registration happens automatically only when the app runs from `~/Applications`, the source installer's destination. A DMG installation in `/Applications` does not register automatically. If macOS requests approval, allow it in the system's Login Items settings.

Menu bar text turns orange or red when macOS reports elevated thermal pressure. This uses the system's thermal state rather than arbitrary temperature thresholds. The app does not control cooling or fan speed.

## Before you use it

- CPU temperature is the **highest readable core sensor**, not an average. It has been **validated on Apple M4 Pro**; sensor compatibility on other chips is unverified. Unavailable values display `—`.
- RAM temperature is not provided. The memory tab shows usage, pressure, compression, and swap.
- Top-three rankings are **per process**, without aggregating an app's processes. CPU percentages are normalized across all logical cores.
- SSD I/O covers the entire internal physical SSD. Network rates cover active `en*` interfaces, excluding VPN and loopback traffic.
- Measurements update every two seconds. Graphs stay in memory; animations run at up to 8fps.

See the [technical details](docs/DETAILS.md) for calculations, units, and compatibility limits. This document is currently in Korean.

## Contributing and license

Report bugs, translation fixes, and feature ideas in [Issues](https://github.com/PIYoung/mac-thermal/issues), or read [CONTRIBUTING.md](CONTRIBUTING.md) before sending a PR. For sensor reports, include your Mac chip and macOS version. Redact personal information and other apps' process names.

The project source code is released under the [MIT License](LICENSE). Copyright and MIT notices for the Stats sensor protocol and key-mapping references are preserved in [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt). The app icon, graphs, and motion are independently implemented; no Stats UI assets are included. Apple symbols and fonts rendered by the system remain subject to their providers' terms. See [asset provenance](ASSET_PROVENANCE.md).
