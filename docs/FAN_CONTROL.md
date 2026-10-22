# Fan control: implementation checkpoint

Status: **UI prototype and deterministic safety policy only**. The installed app
has not been replaced. No privileged helper, installer, IPC endpoint, SMC writer
or automatic fan adjustment is included in this change. Do not describe this as
working fan control or release it as a completed feature.

## Prepared behavior

- The CPU temperature card keeps actual fan RPM and adds a small **Fan control**
  entry. Its detail view uses the existing 308×277 body inside the 340×420 panel.
- Intended actions are **Apple automatic** and **Boost cooling for 10 min**.
  They are disabled in this checkpoint. The view explicitly says that setup is
  pending and the current control mode is unverified. It never infers control
  mode from a spinning fan or a disconnected service.
- Monitoring still reads the existing FNum/FnAc values. Viewing the prototype
  adds no polling, timer, process enumeration, network access or permissions.
- The original `FanBoostSession` policy has a fixed 600-second lease, fresh
  automatic-mode evidence, an 8-second startup timeout and a 6-second heartbeat
  timeout. Duplicate start requests cannot renew it. Cancellation, sleep,
  disconnect and error paths request restoration. Late replies cannot revive a
  cancelled lease. Failed restoration retains ownership and is never shown as
  success until a matching readback confirmation is received.
- The policy emits intents only; it does not communicate with hardware. A future
  helper must enforce it independently using the continuous boot clock. Client
  code and a UI countdown alone cannot guarantee crash recovery.

## Security review required before the next step

The repository's AGENTS.md requires prior review for a new administrator helper
or expanded privileges. General permission to add a feature does not approve
installing a root service or writing fan-control keys.

Proposed **local test installation**, requiring explicit approval:

| Target | Proposed scope |
| --- | --- |
| `/Library/PrivilegedHelperTools/local.mac-thermal.fan-helper` | Root-owned, narrowly scoped helper executable |
| `/Library/LaunchDaemons/local.mac-thermal.fan-helper.plist` | Root launch service; restarts after helper failure |
| `/Library/Application Support/Mac Thermal/FanControl/` | Root-only client pin, approved user ID and owned-lease recovery marker |
| AppleSMC fan-control keys | Hardware maximum for a fixed 10 minutes, or restoration to Apple automatic; no custom low RPM or fan stop |

Authentication must fail closed. This Mac has no usable Developer ID Application
or Apple Development signing identity at this checkpoint. The current ad-hoc app
must **not** be trusted by an empty Team ID, an empty certificate match, executable
name, PID alone or a user-writable allowlist. A local test approach can pin exact
reviewed code hashes in root-owned configuration and enforce peer requirements
with the public `xpc_connection_set_peer_code_signing_requirement` API, available
since macOS 12. Both peers and the allowed user must be checked. A changed app
binary requires a fresh reviewed pin; this is not a consumer distribution plan.
No endpoint or installer has been implemented yet.

The service would accept only status, fixed-duration boost, heartbeat and restore
operations. It must not accept arbitrary keys, RPM values, durations, shell
commands, file paths or executable payloads from clients. No server, account,
telemetry or outbound data flow is needed.

Before any write, validate every fan's maximum, automatic mode, readable mode
keys and exclusive ownership. Unknown/partial values or existing manual control
must refuse startup. Persist an owned-lease recovery marker **before** the first
write. Refuse a new lease if persistence fails. Service startup with an owned
marker must restore and read back automatic mode before accepting new work;
startup without a marker must not reset another application's fans.

SMC mode keys differ across Apple Silicon generations. Some implementations also
use a global test/unlock key, which changes control handoff with macOS. Neither
key readability nor another application's implementation proves this machine's
write permission, reliable control handoff or restoration. Any required global
unlock must be included in the user's approved scope and tested explicitly.

Expected effects include louder fans and increased power use. Bugs, competing
fan-control apps, failed writes or failed recovery can leave control in an
unexpected mode. The first hardware test must be short, attended and cancellable.
Helper crash/restart, app termination, disconnect, sleep/wake, partial writes,
readback failure and the full 10-minute deadline require physical verification.
Launchd restart is a recovery mechanism, not proof of recovery in all failures.

Rollback must first restore and read back automatic mode, then unload and remove
the helper, launch service and root-only configuration. If readback fails, retain
the recovery marker and show the error; never silently remove the only recovery
mechanism. The alternative is to keep the existing read-only monitoring without
any helper. Broad distribution remains blocked on a supported signing/update
strategy and completed hardware/security checks.

## Checks

```sh
zsh scripts/run_fan_boost_probe.sh
zsh scripts/run_panel_updates_probe.sh --fan-preview=/private/tmp/mac-thermal-fan-preview
```

These use synthetic fixtures and isolated preferences. They prove policy and UI
behavior, **not** actual SMC writes, root-service authentication, crash recovery,
sleep/wake restoration or cooling effectiveness.

An optional developer preflight reads numeric fan keys without changing them:

```sh
zsh scripts/run_fan_readonly_preflight.sh --live
```

It is deliberately absent from the automatic checks and production sampling
loop. Failure inside a restricted execution environment is not proof that the
hardware lacks a sensor. Its output is local; nothing is uploaded.

## References and license

- Existing MIT-attributed SMC decoder: `Sources/ThermalSensors.c` and
  `THIRD_PARTY_NOTICES.txt`.
- Protocol investigation: [Stats smc.swift, fixed revision d31a662](https://github.com/exelban/stats/blob/d31a662624eec1fd59239ecb4142cfbac1a37d72/SMC/smc.swift).
  [MIT license](https://github.com/exelban/stats/blob/d31a662624eec1fd59239ecb4142cfbac1a37d72/LICENSE)
  verified 2026-10-22. No Stats fan writer, helper implementation, UI or assets
  are copied into this checkpoint.
- Public XPC peer requirement API: installed macOS SDK
  `usr/include/xpc/connection.h`. NSXPCConnection's public header does not expose
  an audit token; private token access and PID-only authentication are excluded.

All new UI, translations and policy code are original project work under MIT.
