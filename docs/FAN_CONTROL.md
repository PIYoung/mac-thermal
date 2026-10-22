# Fan control — local implementation and review

The AppKit controls, authenticated XPC client, root helper, bounded SMC adapter,
recovery journal and local installation/uninstallation scripts are implemented.
Administrator installation and authenticated app-to-root-service status were
verified on 2026-10-22. An attended 3,000-RPM test exposed delayed SMC visibility:
the first immediate read still showed automatic, while a later independent read
showed manual mode and approximately 3,000 RPM. The original helper incorrectly
cleared recovery too early. A user-run one-shot mode-0 recovery restored Apple
automatic; independent later reads confirmed mode 0 at approximately 1,000 RPM.
After separately approved reinstallation, the corrected build passed physical
3,000-RPM start/readback, explicit cancellation, normal app termination recovery,
hidden-panel operation and the full ten-minute timeout on Mac16,11 / macOS 26.5.2.
Automatic mode was independently confirmed and the app left running. See
[the attended test report](FAN_CONTROL_TESTS.md) for times, exact build hashes and
remaining untested paths. This remains a local development build; these tests do
not establish compatibility across Macs or distribution readiness.

The CPU entry opens a fixed 308×277 body inside the existing 340×420 panel.
There is no repeated page title. The borderless blue `‹ CPU` back control matches
Disk cleanup. The target RPM slider uses 100-RPM steps. Choose the target before
starting a fixed 10-minute cooling session; use Apple automatic to end it early.

## RPM and safety policy

- The service independently reads every fan's actual/minimum/maximum RPM and
  mode. The selectable lower bound is the larger of current speed and hardware
  minimum, rounded up to 100 RPM. The upper bound is the smallest fan maximum,
  rounded down to 100 RPM. No guessed limits, fan stops or intentional lowering
  below the current speed are accepted. All fans use the selected valid target.
- Changing fan modes/targets is isolated in the helper executable. The app's
  metrics collector remains read only. Only per-fan `FnMd`/`Fnmd` and `FnTg`
  keys may be written. No `Ftst` or other global test/unlock writes are made.
  Firmware refusing direct mode changes makes the operation fail and recover;
  it does not cause an authentication or firmware-control bypass.
- The service starts a fixed 600-second lease before the first possible write.
  A repeated start cannot extend it. Its journal is persisted before writes.
  Heartbeats reuse the app's existing two-second resource tick; the root service
  independently checks an active lease and six-second heartbeat timeout every two
  seconds (the watchdog timer is parked while idle) using a continuous boot clock that includes sleep.
- Disconnect, explicit cancel, startup failure, sleep and app exit request Apple
  automatic mode. The service registers system power notifications independently
  of the app. Restart with an owned journal restores automatic mode before
  accepting new work; a new service with no journal leaves other apps' modes
  alone. A foreign manual mode or readable active global test gate blocks start.
- Missing/invalid CPU temperature, a measured CPU temperature of 100°C or above,
  serious/critical macOS thermal pressure, missing hardware data, changed target
  readback or maintenance ends the session. These are conservative app policy
  checks, not manufacturer temperature limits or an overheating diagnosis.
- Queued startup writes are distinct from verified active cooling. The service
  shows a starting state and checks mode/target on a later tick, with an independent
  eight-second startup deadline. It never clears ownership after a same-call
  automatic read when a start may still be in flight.
- Owned recovery always sends per-fan mode 0, even when an immediate read already
  says automatic. It repeats at the existing two-second cadence and retains the
  durable journal until at least six separated observations show all fans
  automatic over at least ten seconds.
  A late manual read resets that interval. Ten seconds is a conservative local
  policy, not a documented firmware guarantee; actual tests remain necessary.
- Automatic mode must be read back on every fan before recovery is reported.
  Restoration does not depend on actual RPM/temperature reads remaining available.
  Failed restoration retains ownership and its recovery journal and retries.
  Unconfirmed recovery is shown as an error, never as successful automatic mode.

A custom RPM can be less cooling than macOS would later request under heavier
load even when it was above the speed at session start. Software safety checks
are not a hardware guarantee. Blocking kernel/SMC calls, other fan-control apps,
firmware differences, OS/power loss and corrupted recovery storage remain limits
that cannot be established by synthetic tests.

## Explicit security review before installation or writes

[AGENTS.md](../AGENTS.md) requires prior review for administrator helpers and
expanded permissions. Permission to implement code is not silently treated as
permission to install a persistent root service or perform physical fan writes.

The proposed local installation changes only:

| Target | Purpose |
| --- | --- |
| `/Library/PrivilegedHelperTools/local.mac-thermal.fan-helper` | Root-owned, non-user-writable helper executable |
| `/Library/LaunchDaemons/local.mac-thermal.fan-helper.plist` | Persistent root launch service with crash restart |
| `/Library/Application Support/Mac Thermal/FanControl/` | Root-only app code hash/UID pin, small owned-lease recovery record and maintenance sentinel |
| AppleSMC per-fan mode/target keys | Selected bounded RPM for at most 10 minutes; restore Apple automatic |

There are no external servers, accounts, network requests, analytics, command
execution endpoint or device-data uploads. The wire protocol accepts only status,
fixed-session boost, heartbeat and restoration, with a bounded JSON payload.
Duration, arbitrary keys, commands, executables and file paths are not accepted.

No usable Developer ID identity is configured on this Mac. This local testing
approach pins the **exact reviewed code hashes and user ID**, not empty Team IDs,
certificate arrays, names, PID checks or user-writable allowlists. The public
`xpc_connection_set_peer_code_signing_requirement` API checks messages on both
ends; the app also requires a root peer. App and helper use hardened-runtime
signatures without debugger, DYLD injection or disabled-library-validation
entitlements. This is necessary for code-hash pins to represent protected code.
A changed app requires a fresh reviewed installation; this is not a consumer
signing, notarization or automatic-update solution.

Root configuration/journal reads reject symbolic links, hard links, oversized
files, non-root ownership and unsafe parent permissions. Journal writes use an
exclusive root-only temporary file, fsync and atomic rename. A failed journal
write cannot start a hardware change. Installation refuses an existing helper or
recovery record rather than overwriting them. Python administrator scripts require
isolated `-I` mode and an embedded exact manifest digest; payload bytes, app code
hash, helper code hash and hardened-runtime flags are verified before bootstrap.
No install script is run by the app or by the build.

## Prepare and inspect, without installation

```sh
zsh build.sh
/usr/bin/python3 -I scripts/prepare_fan_installation.py "$PWD/build/Mac Thermal.app"
```

Inspect `build/fan-control-installation/REVIEW.txt`, `MANIFEST.json`, `install.py`
and `uninstall.py`. The package includes the exact signed helper and MIT notices.
It records the reviewed app path and hash. Prepare it again only if the reviewed
app build/path changes. Do not install a package for an unreviewed app or edit its
manifest to bypass a mismatch. Keep the matching package for uninstallation.

After explicit approval, the installer must be run by the user with administrator
privileges using `/usr/bin/python3 -I` and the package's exact `install.py` path.
Authentication secrets must be entered directly in the system/terminal prompt,
never sent through chat. No automatic sudo, permission-prompt handling or security
setting changes are included. The first test should be short and attended.

RPM noise and power use may increase. Before release, the corrected actual control/readback,
partial failure, cancellation, full timeout, app/helper termination, helper crash
restart and sleep/wake recovery need physical verification on supported hardware.
Passing builds/mocks or reading fan keys does not prove these behaviors.

## Rollback

Run the matching package's reviewed `uninstall.py` with isolated Python and
administrator privileges after approval. It creates a root-only maintenance
sentinel **before** signaling the helper, prevents new starts, waits for the
owned journal to clear and runs a read-only automatic-mode verification. Only
then does it unload the service and remove the exact installed files. Failure
keeps the helper/recovery data; there is no force-delete or force-unload bypass.
The alternative is to leave the app in read-only monitoring without a helper.

## Checks and sources

- `scripts/run_fan_boost_probe.sh`: lease policy, stale acknowledgements/timeouts.
- `scripts/run_fan_service_probe.sh`: injected hardware/journal engine, RPM limits,
  persist-before-write, ownership, partial failure, thermal/sleep/disconnect and
  simulated service restart. No real root files or hardware are used.
- `scripts/run_fan_writer_probe.sh`: synthetic SMC calls, fixed write-key scope,
  firmware errors, mode readback and restoration without RPM data.
- `scripts/run_fan_xpc_auth_probe.sh`: anonymous unprivileged local endpoints,
  matching/wrong client/server code hashes and invalid requirements. This is not
  a privileged Mach service installation test.
- `scripts/run_panel_updates_probe.sh`: four-language layout, `‹ CPU` style,
  selected RPM callback, bounds and active-session display with synthetic values.
- `scripts/fan_installer_probe.py`: nonprivileged installer input boundary checks.
- `scripts/run_fan_readonly_preflight.sh --live`: optional numeric sensor/key
  investigation. It never writes fan keys and is absent from automatic tests.

SMC protocol investigation used [Stats smc.swift at d31a662](https://github.com/exelban/stats/blob/d31a662624eec1fd59239ecb4142cfbac1a37d72/SMC/smc.swift).
Its [MIT license](https://github.com/exelban/stats/blob/d31a662624eec1fd59239ecb4142cfbac1a37d72/LICENSE)
was verified on 2026-10-22. Existing SMC decoder attribution and full MIT notices
are preserved. The new writer, service, client, installer, UI and tests are
original project code; no upstream helper/writer code, UI or assets are copied.
XPC, code-signing and power-notification APIs are based on the installed public
macOS SDK headers. No private audit-token APIs are used.
