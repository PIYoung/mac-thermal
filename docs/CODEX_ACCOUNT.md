# Optional Codex account quota

The Codex panel’s person icon opens a separate account review. Local metrics and local UTC-day token records work without an account. Mac Thermal does not require an API key or make paid model calls for quota lookup; ChatGPT/Codex account eligibility and limits still apply.

After explicit consent, Mac Thermal uses **Codex’s documented managed ChatGPT device-code login**. A supported, independently installed OpenAI-signed Codex executable is required. The official page is `https://auth.openai.com/codex/device`. Complete sign-in there; never paste credentials, device codes or login tokens into chat or issue reports. If your account does not allow device-code sign-in, cancel. The app does not change account security settings or use an undocumented endpoint as a fallback.

This uses managed app-server authentication for a local open-source application. It does not import desktop credentials or use the internal `chatgptAuthTokens` mode. It is also distinct from the newer direct Sign in with ChatGPT tokens for Responses API applications: those tokens are not assumed to support account quota lookup.

## Display

- The menu robot retains its local-record activity animation. A static **quota ring** appears beside it only when account quota is enabled. The ring uses the lowest remaining percentage across returned Codex windows. Orange is below 25%, red below 10% or when the server reports restricted access. A dashed ring means the percentage is unknown; it is never an invented empty/full quota.
- The existing 300×420 Codex panel shows returned short/long quota windows at the top. Duration labels come from the server, such as `5h` and `7d`; these are not fixed plan promises. Each row shows remaining percentage and a reset countdown. The local token/model cards stay separate.
- Quota normally refreshes once a minute. Manual/reset-triggered refresh is throttled to 15 seconds. The existing two-second UI tick updates countdowns, with no new high-frequency timer. Old data becomes unknown after 180 seconds. An expired reset awaits server confirmation and never automatically restores the percentage or account access.
- Some plans or CLI versions may not return both windows or a reset time. Missing fields stay unknown. Billing, spending limits, exact account-wide token totals, NPU usage and verified active-work duration are not inferred from quota.

## Authentication and removal

Authentication can authorize more than statistics-only access. The app’s RPC allowlist limits its own requests, not the credential’s provider-side scope. Only initialization and account read/login/cancel/logout/quota methods are sent. No threads, tools or model calls are requested.

Codex stores this connection separately under `~/Library/Application Support/Mac Thermal/Codex Account`, with a private 0700 directory and its file credential store. The app never parses stored authentication. It does not access `~/.codex/auth.json` or import existing Codex configuration. The helper runs as the current user, communicates over private stdio, and is not a privileged service or public listener. Analytics are disabled for this helper. No helper binary is bundled; the app verifies the installed executable against OpenAI’s Apple signing team before launching it.

Disconnect stops further polling, requests logout, closes the helper, and removes only the isolated `auth.json` without reading it or following a symlink. An unlink failure is reported. Existing Codex authentication is unaffected. Provider access can also be revoked in the account. Approved connections resume after app relaunch/wake; no interactive login starts automatically. System sleep stops the helper.

## Evidence and limits

Protocol/schema checked against installed **codex-cli 0.162.0-alpha.17.2** on 2026-10-20. Other versions may fail closed and require an updated supported Codex app. Synthetic probes cover strict numeric parsing, expiry/staleness, bucket selection, official login URL validation, RPC allowlisting, disconnection races, isolated-store ownership/symlinks, ring cache/spacing and four-language fixed panel bounds. Synthetic previews do not prove live account authentication or quota retrieval; that requires a separately approved user login.

Official references: [Codex app-server](https://learn.chatgpt.com/docs/app-server), [direct Sign in with ChatGPT](https://developers.openai.com/siwc/token-sharing-open-source/sign-in), [SIWC Codex bridge](https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server).
