# Releases

## v2.6.0 — Unreleased

Choose individual menu bar metrics and review disk cleanup candidates. Build 24.

- Show CPU, GPU, SSD, and network by default, with four independent checkboxes in Settings. Save choices across launches and migrate the old primary-metric preference.
- Fit each visible group to its actual text width with compact, consistent spacing, including between SSD and network. Hidden groups leave no reserved space.
- Keep a small clickable MT button when every metric is unchecked so Settings remains accessible.
- Animate only visible active metrics, preserving the 8fps cap, Reduce Motion, sleep behavior, and fixed panel position.
- Validate all 16 visibility combinations, persistence, migration, checkbox actions, four-language layout, and unchanged panel dimensions.

- Put Disk cleanup at the top right of the SSD capacity card. Show used / total (percentage), the usage bar, and available space without resizing the panel.
- Add an on-demand selected-folder scan, reviewed candidate list, explicit selected-file confirmation, cancellable Trash moves, and per-item results. Moving to Trash is distinct from reclaiming space; permanent deletion and blanket cache removal are not supported.
- Exclude known cloud/system locations, links, hidden items and package contents; revalidate file identity and scope before a move. Keep metadata local and preserve the no-helper, no-extra-permissions design.
- Add isolated cleanup safety checks, four-language UI text, and updated native SSD previews.

- Remove the redundant cleanup title and add 24pt to the file list. Keep back navigation and folder controls in one row.
- Remember an explicitly selected folder and inspect it on later cleanup entry, with stable scope checks and a Forget folder action. Never scan on application launch or ordinary panel/tab reopening.
- Precheck only old installer candidates after a complete scan; leave large files and incomplete scans unchecked. Keep exact final confirmation and per-file revalidation before moving anything to Trash.
- Keep cleanup primary-action labels white and semibold on a blue button, including inactive windows, with distinct pressed and disabled colors.

## v2.5.1 — 2026-10-19

CPU and GPU together, with more reliable panel opening. Build 18.

- Display CPU and GPU together by default, alongside SSD and network. Keep CPU-only and GPU-only options and preserve existing explicit choices.
- Add only the GPU slot width in combined mode; apply mode changes immediately without moving an already-open panel.
- Bound panel-opening retries even when the activation notification is missing, and cancel stale callbacks after close or rapid reopen.
- Keep native Settings popups open by dismissing the panel on app deactivation instead of key-focus changes alone.
- Verify all three menu modes, cancellation/activation edge cases, native popup behavior, and the unchanged panel size. Refresh the four-language documentation and menu demonstration.

## v2.5.0 — 2026-10-19

GPU monitoring and animated menu bar tiles. Build 17.

- Add a GPU tab with driver-reported utilization, a fixed 0–100% graph for the last minute, model, and core count. Keep the 380×468pt panel.
- Choose CPU or GPU for the first menu bar item in Settings; CPU remains the default and the menu bar width stays unchanged.
- Represent GPU usage with an original 4×3 tile grid and a gentle brightness wave. The 12 cells are usage steps, not physical cores. Respect motion preferences, Reduce Motion, sleep, and the existing 8fps limit.
- Read GPU metrics through IOKit without administrator access, a helper, new dependencies, or network requests. Unsupported fields remain unavailable rather than appearing as zero.
- Preserve the selected resource tab when upgrading; keep language selection at the top of Settings.
- Update all four language versions and synthetic native screenshots. Add GPU parsing, menu rendering, history, and migration checks.

GPU readings were verified on Apple M4 Pro. The driver registry fields are undocumented and availability can vary with the chip and macOS version. GPU temperature and Neural Engine utilization are not included.

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
