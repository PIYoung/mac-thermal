# Releases

## v2.4.0 — 2026-10-15

Resource-focused tabs and lower background overhead. Build 16.

- Replace Overview, Memory, Top 3 and SSD with CPU, Memory, SSD and Network tabs, retaining the fixed 380×468pt panel.
- Put the CPU and memory top-three process lists beside their corresponding resource metrics. Keep CPU and SSD temperatures as supporting information.
- Give network upload/download rates and graphs a dedicated tab. Open CPU initially, then remember the last selected tab.
- Update the four-language README files and panel preview for the new layout.
- Resolve process names only for the final CPU/memory top-three entries, reusing names for shared PIDs.
- Reuse menu bar text measurements across animation frames while preserving the existing appearance and 8fps limit.
- Defer hidden panel and inactive tab display updates while retaining measurement history and showing the latest values when opened.
- Skip unused HID CPU events when valid SMC CPU readings already take priority; preserve sensor fallbacks.
- Add synthetic ranking, sensor fallback, cache invalidation and panel lifecycle regression checks.

## v2.3.0 — 2026-10-15

First public release of Mac Thermal. Created with AI assistance using OpenAI Codex and iterative user feedback. MIT licensed.

- CPU temperature/utilization, SSD read/write and network transfer rates in the menu bar.
- Overview, Memory, Top 3 processes and SSD tabs; uptime and system thermal state.
- Rhythm bars or orbiting dots, network flow and SSD activity waves; motion preferences and Reduce Motion support.
- Korean default, English, Japanese and Simplified Chinese. The language selector is at the top of Settings.
- Apple Silicon ARM64, macOS 14 or later. CPU sensors validated on Apple M4 Pro; other hardware compatibility is unverified.
- DMG and ZIP downloads with SHA-256 checksums; local source build installer.

The binary is ad-hoc signed and is not Developer ID signed or notarized. macOS may block a downloaded copy. Source builds require the macOS 26 SDK. See the README for installation and compatibility details.

Only the current reviewed source and newly built application are published. Earlier local development builds are not part of this public release.
