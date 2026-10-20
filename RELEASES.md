# Releases

## v2.13.1 — 2026-10-20

Independent temperature warnings, fan RPM and home-directory disk cleanup. Build 47.

- Add GPU temperature and explicitly labeled memory proximity temperature to the fixed-size resource panels. Use verified M4-family SMC mappings or explicitly named GPU HID sensors, exclude PMU substitutions, and show unknown for unsupported or invalid readings. Live M4 Pro readings were verified; compatibility on other models is not guaranteed.
- Color only the affected CPU, GPU or SSD menu group. Show each panel temperature warning independently; memory pressure remains separate from memory proximity temperature. Keep usage graphs, network and Codex colors independent. App display thresholds are CPU/GPU 90°C/100°C, SSD 60°C/70°C and memory proximity 75°C/85°C; they are explained in tooltips and are not manufacturer limits or an overheating diagnosis.
- Add read-only fan running/stopped status and actual RPM to the CPU panel. Distinguish an unavailable sensor from stopped fans and an explicitly reported fanless device. No fan control, administrator helper, extra timer or external package.
- Start disk cleanup from an explicit home Auto scan button without requiring a folder picker. Read local metadata only, exclude protected/development/known-cloud locations and links, keep every home candidate unchecked, and require exact final review before moving selected files to Trash. Retain optional remembered one-folder scanning, bounded cancellation and partial-result warnings. No permanent deletion, Full Disk Access request or automatic scan on app launch.
- Preserve 340×420pt resource and 300×420pt Codex surfaces, fixed positioning, two-second resource sampling, four languages, opt-in Codex account features and the existing privacy boundaries. Refresh documentation with synthetic screenshots only.
- Validate the full native suite, per-metric warning pixels/recovery, missing sensors, four-language layouts, sensor read-only commands and synthetic cleanup safety; check the installed GPU/memory/fan panels on an M4 Pro.

Apple Silicon · macOS 14+. DMG, ZIP and SHA256SUMS are provided. Community builds are ad-hoc signed, without Developer ID signing or Apple notarization. MIT licensed; bundled notices are preserved. Made with OpenAI Codex and user feedback.

## v2.11.1 — 2026-10-20

Optional Codex quota-reset notifications and matching settings scrolling. Build 44.

- Add a default-off “Quota reset notifications” switch below local record reading in Settings. Request macOS alert permission only when explicitly enabled; preserve the choice across launches.
- Reuse existing quota responses to notify once when the server confirms a new quota window. Countdown expiry alone, startup, sign-in, duplicate/stale responses and long sleep do not trigger catch-up alerts. Simultaneous window resets produce one notification.
- Show only “Mac Thermal” and a localized “Codex quota has refreshed” message, without account names or token counts. Alerts may appear on the lock screen depending on macOS settings. The app must be running and account quota connected; macOS Focus and notification preferences control presentation. Switching off stops delivery and clears this feature’s pending/delivered alerts.
- Use the same original slim blue-to-teal scrollbar in Settings and the Codex companion, with interaction emphasis and native drag, paging and accessibility. Keep panel dimensions and position fixed.
- No new server, extra quota requests, model calls, developer telemetry or external packages. Reset detection retains only numeric window baselines in memory. Verify with synthetic quota/notification transport checks, four-language panel/layout checks and the full build suite; actual future resets are not part of the local test.

Apple Silicon · macOS 14+. DMG, ZIP and SHA256SUMS are provided. Community builds are ad-hoc signed, without Developer ID signing or Apple notarization. MIT licensed; bundled notices are preserved. Made with OpenAI Codex and user feedback.

## v2.10.5 — 2026-10-20

Codex account insights and a refined scrolling companion. Build 42.

- Add optional Codex-managed ChatGPT sign-in for remaining quota and reset countdowns. Use an independently installed OpenAI-signed helper with a private, isolated credential store; never import existing desktop credentials or make model calls.
- Keep daily account statistics and five lifetime/peak/streak/longest-turn summary values behind separate default-off reviews. Missing or stale values remain unknown; disabling clears the approved in-memory data. No developer collection server, analytics SDK, remote logging or usage-history files.
- Show local input/output composition, cache reuse, reasoning share and model TOP 3; click a model to expand details. Keep local UTC-today records distinct from account-wide statistics. Local record reading moves to Settings, directly below Language.
- Keep the original title header and fixed 300×420pt companion. Scroll the quota card with the other cards, using an original translucent 3pt thumb that emphasizes during interaction while preserving native drag, paging and accessibility.
- Update four-language documentation and synthetic Codex previews. Retain the compact menu robot, menu animation limits, paired-panel placement and reviewed disk cleanup.

Apple Silicon · macOS 14+. DMG, ZIP and SHA256SUMS are provided. Community builds are ad-hoc signed, without Developer ID signing or Apple notarization. MIT licensed; bundled notices are preserved. Made with OpenAI Codex and user feedback.

## v2.7.1 — 2026-10-20

Reduce menu bar rendering overhead. Build 29.

- Cache text rasters and the current animation frame for AppKit’s alternating status-item appearances, reuse layout while labels stay the same, and skip redundant effective-appearance notifications. Keep light/dark contrast, warning colors and accessibility/language invalidation.
- Remove a redundant full-image crop and avoid setting the status-item width when it has not changed.
- Preserve the eight-frame-per-second animation limit, monitoring cadence, motion gates and paired-panel layout.
- Verify repeated appearance changes reuse cached text with identical pixels and fresh measurements invalidate the cache. No external dependencies or permissions are added.
- Record local CPU observations and measurement units in [docs/PERFORMANCE.md](docs/PERFORMANCE.md); results depend on workload and are not a fixed performance guarantee.

## v2.7.0 — 2026-10-19

Compact resource surfaces and an optional local Codex companion. Build 28.

- Relayout every resource page, settings and disk cleanup in a 340×420pt surface, retaining readable type and existing controls.
- Show a separate 300×420pt Codex surface to the left of the resource panel when Codex is running. Keep both surfaces in one presentation host with a fixed opening position, a 12pt visible gap and pass-through shadow margins; narrow displays use a vertically scrollable pair.
- Show Codex app runtime from macOS launch metadata. With explicit opt-in, read model identifiers, token counters and timestamps from local Codex session records. Display UTC-today totals and model shares for this Mac; account quota, API billing and verified work duration are unavailable.
- Keep record reading off by default, bounded and read-only. Turning it off stops reads and clears memory. Source files contain conversations, but bodies, commands, credentials and instructions are never retained, logged or transmitted. No account request, CLI helper, new server, Codex setting change, API key or model generation is added.
- Use validated counter deltas and mark incomplete scans. Keep aggregates in memory and leave missing values unavailable.

- Add an independently selectable, icon-only Codex robot at the left of the resource menu items while the desktop app is running. Keep token totals and last-record age in the panel and tooltip. The robot types after newly observed recent usage records and stops after 10 seconds without another record; initial scans, app runtime and old catch-up records never imply live task status. Respect motion-off, Reduce Motion and sleep.
- Migrate existing menu selections while adding the new Codex item; preserve subsequent opt-outs. Validate all 32 selections, both appearances, four languages and fixed left-side companion ordering.

- Simplify all four READMEs and refresh small native previews for the compact panels and leading Codex icon.

## v2.6.0 — 2026-10-19

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
