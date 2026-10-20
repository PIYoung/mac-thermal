# Optional Codex account quota

The Codex panel’s person icon opens a separate account review. Local metrics and local UTC-day token records work without an account. Mac Thermal does not require an API key or make paid model calls for quota lookup; ChatGPT/Codex account eligibility and limits still apply.

After explicit consent, Mac Thermal uses **Codex’s documented managed ChatGPT device-code login**. A supported, independently installed OpenAI-signed Codex executable is required. The official page is `https://auth.openai.com/codex/device`. Complete sign-in there; never paste credentials, device codes or login tokens into chat or issue reports. If your account does not allow device-code sign-in, cancel. The app does not change account security settings or use an undocumented endpoint as a fallback.

This uses managed app-server authentication for a local open-source application. It does not import desktop credentials or use the internal `chatgptAuthTokens` mode. It is also distinct from the newer direct Sign in with ChatGPT tokens for Responses API applications: those tokens are not assumed to support account quota lookup.

## Display

- Account quota is shown only in the Codex panel. The menu robot retains its original compact local-record activity animation and runtime-based visibility, without a quota ring or quota tooltip.
- The existing 300×420 Codex panel shows returned short/long quota windows at the top. Duration labels come from the server, such as `5h` and `7d`; these are not fixed plan promises. Each row shows remaining percentage and a reset countdown. The local token/model cards stay separate.
- Quota normally refreshes once a minute. Manual/reset-triggered refresh is throttled to 15 seconds. The existing two-second UI tick updates countdowns, with no new high-frequency timer. Old data becomes unknown after 180 seconds. An expired reset awaits server confirmation and never automatically restores the percentage or account access.
- Some plans or CLI versions may not return both windows or a reset time. Missing fields stay unknown. Billing, spending limits, exact account-wide token totals, NPU usage and verified active-work duration are not inferred from quota.

## Daily usage graph

The existing 300×420 companion shows a dedicated daily account graph and a separate local model TOP 3 card at the same time. The graph uses an original smooth line, a restrained gradient area and actual daily point markers. Hovering a point shows its date and token count. There is no graph/model toggle; missing graph data does not hide the local models.

Daily account statistics require a separate in-app review because the data scope expands beyond quota. This optional setting is off by default, including for previously connected quota accounts. Once approved, `account/usage/read` is requested with empty parameters, never a thread ID. Only returned date/token buckets are retained in memory. Summary fields, thread usage, raw errors and conversation contents are not retained. No local record is uploaded. The account-statistics button manages refresh/disconnection independently of the quota connection.

The existing quota timer checks for a graph refresh about every five minutes; explicit refresh is limited to once per 15 seconds. The graph is hidden when its data is more than 15 minutes old. Disabling statistics clears its data and ignores pending replies; account disconnect clears both approvals. Sleep/logout/helper failure clears graph values, and an approved saved connection can resume after wake/relaunch. An unsupported/error/empty daily-statistics response does not break quota or generate sample values.

The graph selects a seven-date window ending on the current UTC date, preserving the service's date-only labels. This does not establish the service's accounting time zone. Missing/invalid/conflicting duplicate dates remain gaps, never zero or interpolated values. Returned zero is a real baseline point. Curves use control points between adjacent values to avoid overshoot, and separate segments at gaps. Dates, integer counts, response size and retained rows are bounded. There is no repeating graph animation or additional high-frequency timer, no external chart dependency and no disk history cache.

## Authentication and removal

Authentication can authorize more than statistics-only access. The app’s RPC allowlist limits its own requests, not the credential’s provider-side scope. Only initialization, account read/login/cancel/logout/quota and separately approved daily-usage methods are sent. No threads, tools or model calls are requested.

Codex stores this connection separately under `~/Library/Application Support/Mac Thermal/Codex Account`, with a private 0700 directory and its file credential store. The app never parses stored authentication. It does not access `~/.codex/auth.json` or import existing Codex configuration. The helper runs as the current user, communicates over private stdio, and is not a privileged service or public listener. Analytics are disabled for this helper. No helper binary is bundled; the app verifies the installed executable against OpenAI’s Apple signing team before launching it.

Disconnect stops further polling, requests logout, closes the helper, and removes only the isolated `auth.json` without reading it or following a symlink. An unlink failure is reported. Existing Codex authentication is unaffected. Provider access can also be revoked in the account. Approved connections resume after app relaunch/wake; no interactive login starts automatically. System sleep stops the helper.

## Evidence and limits

Protocol/schema checked against installed **codex-cli 0.162.0-alpha.17.2** on 2026-10-20. Other versions may fail closed and require an updated supported Codex app. Synthetic probes cover strict numeric parsing, expiry/staleness, bucket selection, official login URL validation, RPC allowlisting, disconnection races, isolated-store ownership/symlinks, panel-only quota/menu isolation and four-language fixed panel bounds. A separately approved live device-code login, account quota response and weekly-window rendering were also verified on this Mac on 2026-10-20. The account returned only a secondary weekly window; the UI centers that single row and does not invent a primary window. Other plans, future CLI versions and reset/restriction recovery remain subject to their returned data. Synthetic previews use example values, not captured account data.

Official references: [Codex app-server](https://learn.chatgpt.com/docs/app-server), [direct Sign in with ChatGPT](https://developers.openai.com/siwc/token-sharing-open-source/sign-in), [SIWC Codex bridge](https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server).

Daily-statistics verification (2026-10-20): after the separate user approval, the installed app successfully read real service buckets and displayed the curve. A missing current-date bucket remained a gap, and quota stayed connected. Four-language fixed bounds, graph/model switching, null/invalid/conflicting dates, true zero, freshness, independent usage errors, five-minute cadence, late replies after disabling, and saved opt-in resumption were checked with synthetic fixtures. No live account values are included in documentation fixtures.

Local record reading is controlled in Mac Thermal Settings, directly below Language. Its privacy explanation and collection status move with the switch; saved consent and collection scope stay unchanged. Settings scroll within the fixed panel. The Codex companion uses a full-width today-token card and separate graph and model cards; the last-record timestamp item is removed.
