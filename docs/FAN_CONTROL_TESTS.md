# Attended local fan-control tests — 2026-10-22

This report distinguishes physical observations from synthetic checks. It covers
one Mac and one locally signed build, not general hardware compatibility.

## Environment

- Hardware model identifier: `Mac16,11`; macOS `26.5.2`.
- Implementation commit: `43af70f608bdea6608235057c23d011362d1536f`.
- Installed app executable SHA256:
  `6ed8005d250d5858a8bb168a86ab5b4b109069d24669f81f651faa2f355d3fea`.
- Installed root helper SHA256:
  `4316c110aa97f9913e6568d9d40093f83942dedef7dddb16b54cf50e7d422427`.
- One fan reported 1,000 minimum and 4,900 maximum RPM. All tests selected
  3,000 RPM, above the actual speed at session start.
- Administrator installation was explicitly approved and performed by the user.
  Code hashes matched the prepared package. The authenticated app read the root
  service's status, limits and control results.

## Observed on this Mac

- An initial start was refused with the thermal-safety issue while the panel had
  shown approximately 100°C. The fan remained automatic. This observation does
  not independently isolate the temperature guard from the pressure guard.
- Around 15:19:54 KST, start first showed target application pending, followed by
  active cooling. Independent read-only SMC reads showed mode 1, target 3,000 and
  actual approximately 2,999–3,003 RPM.
- Around 15:20:04, Apple automatic was requested. The UI retained a restoration
  confirmation state, then returned to automatic. A later independent read showed
  mode 0, actual 1,492 RPM and an automatically changing target of 1,495 RPM.
- A second session reached mode 1 and actual/target 3,000 RPM. Only the app was
  terminated with normal SIGTERM; the root helper remained running with the same
  PID. A later independent read showed mode 0, actual/target 1,000 RPM. Relaunch
  showed the CPU panel and recovered automatic status.
- The full-duration session started around 15:21:42. The panel was dismissed
  during the session; the app stayed running and independent fan reads continued
  to show the selected 3,000-RPM target. The fixed lease did not rely on panel
  visibility.

- Full-duration timeout passed: mode 1 and target 3,000 RPM were still observed
  at 15:31:33. At 15:31:43, without cancellation, mode changed to 0, the automatic
  target was 1,000 RPM and actual RPM was falling through 1,273. Observations at
  15:31:53, 15:32:03, 15:32:13 and 15:32:22 remained in mode 0 near 1,000 RPM.
  These approximately ten-second samples bracket the change; they do not measure
  subsecond timing. The session began around 15:21:42, consistent with the fixed
  600-second deadline and the independent watchdog.
- All 63 read-only monitor samples succeeded. The same app process stayed alive
  while its panel was hidden. After timeout, the app was normally restarted to
  reopen its panel. Authenticated status showed Apple automatic and enabled the
  RPM picker/start button, confirming that no owned recovery remained pending.
  The app was left running in automatic mode with its fan settings page open.

The temporary attended monitor recorded only elapsed time, CPU temperature,
actual/target RPM, mode and read success every approximately ten seconds. It
performed no fan writes or network requests. The test file is local and is not
application telemetry or committed raw user data.

## Synthetic verification and remaining limits

Build, four-language localization/layout, delayed start/readback and automatic
settlement regression fixtures, fixed 600-second policy, journal-before-write,
ownership, partial-write/recovery failures, simulated sleep/restart and wrong
XPC code-hash rejection passed. Synthetic tests do not prove their physical
counterparts.

Physical sleep/wake, root-helper crash/restart, corrupted root storage and
hardware/OS variations were not exercised. No global SMC test/unlock keys were
written. These results do not establish a universal temperature limit, cooling
effect under controlled load, battery/noise impact, or distribution readiness.
