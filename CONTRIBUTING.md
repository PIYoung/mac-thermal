# Contributing to Mac Thermal

Thanks for helping improve Mac Thermal. Bug reports, hardware compatibility reports, translations, and focused pull requests are welcome.

## Report a bug

Search [existing issues](https://github.com/PIYoung/mac-thermal/issues) before opening a new one. Include:

- App version, macOS version, and Mac chip model.
- What you expected, what happened, and steps to reproduce it.
- Whether a sensor shows `—`, a value looks wrong, or the app fails to launch.
- A screenshot when useful, with personal information and other apps' process names redacted.

Do not post credentials, full process dumps, private file paths, or unrelated system logs. A missing sensor does not justify changing system security settings or granting the app additional privileges.

## Build and check

Use an Apple Silicon Mac with Xcode 26, or compatible Command Line Tools containing the macOS 26 SDK. The deployment target is macOS 14. The current release has been exercised on Apple M4 Pro; other hardware reports help establish compatibility.

```sh
git clone https://github.com/PIYoung/mac-thermal.git
cd mac-thermal
zsh scripts/check.sh
```

To build without running the checks, use `zsh build.sh`. To build and install locally, use `zsh scripts/install.sh`; add `--open` to launch afterward. Quit an existing Mac Thermal instance before replacing it. No `sudo` is required.

The checks use isolated preference domains. Do not add tests that modify the user's actual language, launch-at-login setting, or menu bar preferences. Real sensor behavior and sleep/wake behavior still need manual verification when affected. See [measurement details](docs/DETAILS.md) for calculations and additional resource probes; this document is currently in Korean.

## Send a pull request

Keep the change focused and explain the problem, resulting behavior, and verification. For UI work, include before/after images using synthetic values where possible. State which macOS and hardware combinations you actually tested, and distinguish those from expected compatibility.

Preserve these project constraints:

- Keep measurements local. Do not add telemetry, accounts, outbound uploads, administrator helpers, or new permissions without prior discussion.
- Show unavailable readings honestly. Do not replace missing measurements with made-up values, and do not label unidentified PMU sensors as RAM temperatures.
- Keep the panel's fixed layout and position, support light/dark appearance and Reduce Motion, and stop idle animation timers.
- Preserve the maximum 8fps menu bar animation limit and use actual measurements to drive motion.
- Avoid introducing dependencies or copying another app's UI, icon paths, charts, or branding.

If a feature needs a new external service, permission, dependency, or license, open an issue before implementing it. Include the intended behavior and any privacy or compatibility impact.

## Translations

App translations live in `PanelTranslations.swift` and `SystemTranslations.swift`. Korean source strings are the keys; each value lists English, Japanese, then Simplified Chinese. Preserve format specifiers such as `%@` and `%d`. Keep labels short enough for the existing panel, and run `zsh run_localization_probe.sh` after changes.

The public READMEs are `README.md` (Korean), `README.en.md`, `README.ja.md`, and `README.zh-CN.md`. Update all four when installation requirements or user-facing behavior changes. Native-language corrections are welcome.

## AI assistance

Mac Thermal was created with OpenAI Codex and iterative user feedback. AI-assisted contributions are welcome. Explain what you changed and verified, and review generated code, translations, and license claims before submitting them. AI output still needs the same testing and source attribution as any other contribution.

## License and attribution

Contributions are provided under this project's [MIT License](LICENSE). Keep existing copyright and permission notices. Before adding third-party material, verify its source and redistribution terms, and update [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt) and [ASSET_PROVENANCE.md](ASSET_PROVENANCE.md) as needed. Required notices must remain packaged with the app.

The app icon and custom graphics are original project work. Apple system symbols and fonts are rendered through system APIs; do not copy them into the app icon, logo, or redistributed asset files.
