<p align="center"><img src="docs/images/app-icon.png" alt="Mac Thermal" width="64" height="64"></p>
<h1 align="center">Mac Thermal</h1>
<p align="center"><strong>Your Mac, at a glance in the menu bar.</strong><br>Apple Silicon · macOS 14+ · MIT</p>
<p align="center"><a href="README.md">한국어</a> · <strong>English</strong> · <a href="README.ja.md">日本語</a> · <a href="README.zh-CN.md">简体中文</a></p>
<p align="center"><a href="https://github.com/PIYoung/mac-thermal/releases/latest"><strong>↓ Download</strong></a> · <a href="RELEASES.md">Changelog</a></p>

<p align="center"><a href="https://github.com/PIYoung/mac-thermal/releases/tag/v2.16.0"><strong>v2.16.0</strong></a> · Ten-minute cooling · Selectable RPM · Automatic return</p>

## Menu bar and panels

<p align="center"><img src="docs/images/menubar.png" alt="Codex robot and CPU, GPU, SSD and network menu bar" width="460"></p>
<table align="center">
  <tr><th>Codex companion</th><th>Resource panel</th></tr>
  <tr>
    <td><a href="docs/images/codex-en-light.png"><img src="docs/images/codex-en-light.png" alt="Codex companion" width="190"></a></td>
    <td><a href="docs/images/panel-en-cpu.png"><img src="docs/images/panel-en-cpu.png" alt="Resource panel" width="215"></a></td>
  </tr>
</table>
<sub>Synthetic examples drawn by the actual app renderer. Translucency varies by macOS version.</sub>

## Features

- **Menu bar:** CPU temperature and usage, GPU usage, SSD read/write rates, network speeds and animated indicators.
- **Click-open panel:** CPU, GPU, memory, SSD and network tabs, recent graphs, top three CPU/memory processes and system uptime.
- **Temperatures and fans:** CPU/GPU/SSD temperatures, memory **proximity temperature**, independent warning colors, and fan status with actual RPM in the CPU panel. Sensor availability varies by device.
- **Ten-minute cooling (experimental):** Choose RPM in 100-RPM steps under CPU → Fan control. A separately installed administrator helper controls fans for at most ten minutes, then returns to Apple automatic. Basic monitoring needs no helper.
- **Guidance and AI help:** Review evidence and suggested actions for each resource tab. Supported macOS 26+ devices can generate short explanations with the Apple on-device model on request; unsupported models, sustained heat or generation errors show a reason and basic guidance.
- **Codex:** A left companion shows local tokens today, input/output, cache reuse and model TOP 3. Optional account quota and activity summaries share a scrolling card layout with an original slim scrollbar.
- **Disk cleanup:** Start a home scan without choosing a folder. Select candidates yourself, then confirm before moving them to Trash. Optional one-folder scanning remains available.
- **Settings:** Choose metrics, ten CPU animation styles, motion and startup at login. Korean by default; English, Japanese and Simplified Chinese supported.

<details>
<summary>v2.16.0 — Optional fan control</summary>

- Select a target at or above current RPM and the hardware minimum, up to the hardware maximum. Keep the compact, title-free page and `‹ CPU` navigation matching Disk cleanup.
- Confirm startup on later readings. Recheck automatic recovery for at least ten seconds and retain its recovery record if unconfirmed. Heat, thermal pressure, sensor errors and disconnects request automatic mode.
- One Mac passed physical 3,000-RPM control, cancellation, app-exit recovery, hidden-panel operation and the full ten-minute timeout. Other Macs, physical sleep/wake and helper crash recovery remain unverified. [Test report](docs/FAN_CONTROL_TESTS.md)

</details>

## Install

1. Download the **DMG** from the [latest release](https://github.com/PIYoung/mac-thermal/releases/latest). ZIP is also available.
2. Open the DMG and drag **Mac Thermal.app** to **Applications**.
3. Launch the app and click its menu bar indicators. Install a newer release to update.

> This build is ad-hoc signed and not notarized by Apple. If macOS blocks it, build from source below instead of disabling security settings. Verify downloads against `SHA256SUMS`.

**If a fan helper is already installed, remove it with its matching old tools before replacing the app.**

**Fan control is a separate opt-in installation.** Use the versioned Fan Tools folder in the DMG or the release’s `fan-tools.zip`. Review the [setup, update and removal guide](docs/FAN_CONTROL_SETUP.md), then perform administrator installation yourself. Launching the app never installs the helper or starts fan control. A fixed RPM may provide too little cooling if load later rises, and can increase noise and power use.

<details>
<summary>Build and install from source</summary>

Requires Apple Silicon and Xcode 26 or compatible Command Line Tools with the macOS 26 SDK.

```sh
git clone https://github.com/PIYoung/mac-thermal.git
cd mac-thermal
zsh scripts/install.sh --open
```

Quit the existing app first. Installs into `~/Applications`; no `sudo` required.

</details>

## Codex records and privacy

Codex record reading is **OFF by default**. When enabled, only model names, token numbers and timestamps from `~/.codex/sessions` are aggregated in memory. These files also contain conversations, but bodies, commands and credentials are never kept, displayed or transferred. Source files are unchanged; switching off stops reading and clears aggregation.

Usage covers <strong>this Mac’s records for today (UTC)</strong>, not account totals or billing. Optional [official sign-in](docs/CODEX_ACCOUNT.md) adds remaining account quota and reset countdowns after separate consent. Daily numeric summaries and lifetime/streak account summaries each require additional opt-in. There is no developer collection server, analytics SDK or remote log upload. The robot moves slowly while Codex is running and actively for 10 seconds after a new token record, then returns to its slow idle cycle. It does not indicate live token consumption or task completion.

Quota-reset notifications are optional in Settings (OFF by default). While the app is running and account quota is connected, a confirmed server reset triggers one local alert. macOS notification permission is required; no additional polling or data collection is added.

---

[Technical details](docs/DETAILS.md) · [Security](SECURITY.md) · [Contributing](CONTRIBUTING.md) · [MIT License](LICENSE) · [Third-party notices](THIRD_PARTY_NOTICES.txt)

<sub>Made with AI assistance using OpenAI Codex and user feedback.</sub>
