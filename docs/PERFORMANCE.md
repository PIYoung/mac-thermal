# Menu bar CPU check — 2026-10-20

Measured on an Apple M4 Pro with all resource menu items, Codex, rhythm animation and local record reading enabled. The CPU resource page and Codex companion were open. Animation remains capped at eight frames per second; resource sampling remains every two seconds.

| Build | Wall time | Process CPU time | CPU, one core = 100% |
| --- | ---: | ---: | ---: |
| v2.7.0, warmed | 30.021 s | 3.8451 s | 12.808% |
| Cached rendering, warmed | 30.024 s | 2.4144 s | 8.042% |
| Final local install | 30.012 s | 2.6800 s | 8.930% |

These are local observations, not a performance guarantee or an isolated fixed-workload benchmark. Other applications, menu activity and changing Codex records affect results. The cached build used roughly 37% less process CPU in the first two pre-UTC-rollover observations. The final install was measured after UTC midnight, when the local record catalog changed; its 8.930% is a current observation rather than a fixed-workload A/B comparison.

## What changed

- Reuse text/layout across AppKit’s transient status-button appearance changes. Cache up to four appearance rasters, keyed by appearance name, backing scale and contrast state.
- Reuse the current composite frame when AppKit requests the same appearance again within a tick. Keep at most eight frame variants, clearing them on phase, sample, preference or forced appearance changes.
- Avoid reassigning an unchanged image, a redundant full-image crop and unchanged status-item widths.
- Retain immediate light/dark and warning-color handling, explicit language/accessibility invalidation, display-wake refresh and the existing motion/sleep gates.

Initial native call-stack sampling found repeated text measurement/rasterization under status-item snapshot appearance KVO. The added probe checks 200 alternating appearances for identical pixels and frame reuse, then verifies fresh samples, warning transitions/recovery and forced appearance changes invalidate cached content. Existing motion, visibility and multilingual layout probes still exercise the same painter.

No parser, sensor cadence, permission, dependency or external data flow was changed.

## Measurement units

Read user + system counters using `proc_pid_rusage(pid, RUSAGE_INFO_V2, ...)` before and after a monotonic wall-time interval. The counters use Mach absolute-time units on this Mac, not nanoseconds:

```text
CPU seconds = delta(ri_user_time + ri_system_time) * timebase.numer / timebase.denom / 1e9
CPU percent = CPU seconds / elapsed wall seconds * 100
```

The measured timebase was 125/3. Omitting this conversion undercounts CPU by about 41.67 times; the initial unconverted readings were discarded. This percentage uses one logical core as 100%, whereas the in-app process TOP 3 divides by the machine’s logical CPU count.

## Validation

The full project check suite passed after the initial cache changes. After the final frame-cache changes, the affected menu rendering probes were rerun successfully, the application was rebuilt and its signature verified. Native CPU/GPU tab switching and installed panel opening were checked. The installed executable was verified to match the final built executable.
