# Optional Codex account quota

The Codex panel’s header person icon opens a separate account review. Local metrics and local UTC-day token records work without an account. Mac Thermal does not require an API key or make paid model calls for quota lookup; ChatGPT/Codex account eligibility and limits still apply.

After explicit consent, Mac Thermal uses **Codex’s documented managed ChatGPT device-code login**. A supported, independently installed OpenAI-signed Codex executable is required. The official page is `https://auth.openai.com/codex/device`. Complete sign-in there; never paste credentials, device codes or login tokens into chat or issue reports. If your account does not allow device-code sign-in, cancel. The app does not change account security settings or use an undocumented endpoint as a fallback.

This uses managed app-server authentication for a local open-source application. It does not import desktop credentials or use the internal `chatgptAuthTokens` mode. It is also distinct from the newer direct Sign in with ChatGPT tokens for Responses API applications: those tokens are not assumed to support account quota lookup.

## Display

- Account quota is shown only in the Codex panel. The menu robot retains its original compact local-record activity animation and runtime-based visibility, without a quota ring or quota tooltip.
- The existing 300×420 Codex panel shows returned short/long quota windows at the top. Duration labels come from the server, such as `5h` and `7d`; these are not fixed plan promises. Each row shows remaining percentage and a reset countdown. The local token/model cards stay separate.
- Quota normally refreshes once a minute. Manual/reset-triggered refresh is throttled to 15 seconds. The existing two-second UI tick updates countdowns, with no new high-frequency timer. Old data becomes unknown after 180 seconds. An expired reset awaits server confirmation and never automatically restores the percentage or account access.
- Some plans or CLI versions may not return both windows or a reset time. Missing fields stay unknown. Billing, spending limits, exact account-wide token totals, NPU usage and verified active-work duration are not inferred from quota.

## Account statistics

The initial viewport presents today's local tokens, an input/output composition card and model TOP 3. Account activity and the seven-day numeric summary sit below them in the same scrolling body. There is no daily graph or ten-minute activity chart. Model rows can expand to show their own input/output/cache/reasoning details.

Daily account statistics require a separate in-app review because the data scope expands beyond quota. This optional setting is off by default, including for previously connected quota accounts. Once approved, `account/usage/read` is requested with empty parameters, never a thread ID. Only returned date/token buckets are retained with daily-statistics consent. A separate summary review authorizes exactly five additional numeric fields; other summary fields, thread usage, raw errors and conversation contents are not retained. No local record is uploaded. The seven-day card's ellipsis manages statistics independently of quota; signed-out users see a sign-in action instead of account data.

The existing quota timer checks for statistics about every five minutes; explicit refresh is limited to once per 15 seconds. Values become unknown after 15 minutes. Disabling statistics clears its data and ignores pending replies; account disconnect clears both approvals. Sleep/logout/helper failure clears values, and an approved saved connection can resume after wake/relaunch. An unsupported/error/empty response does not break quota or generate sample values.

The numeric summary uses the seven UTC date labels ending today. This does not establish the service's accounting time zone. Missing/invalid/conflicting duplicate dates are excluded from averages; returned zero is real data. Counts, response size and retained rows are bounded. No chart dependency, additional high-frequency timer or disk history cache is used.

## Authentication and removal

Authentication can authorize more than statistics-only access. The app’s RPC allowlist limits its own requests, not the credential’s provider-side scope. Only initialization, account read/login/cancel/logout/quota and separately approved daily-usage methods are sent. No threads, tools or model calls are requested.

Codex stores this connection separately under `~/Library/Application Support/Mac Thermal/Codex Account`, with a private 0700 directory and its file credential store. The app never parses stored authentication. It does not access `~/.codex/auth.json` or import existing Codex configuration. The helper runs as the current user, communicates over private stdio, and is not a privileged service or public listener. Analytics are disabled for this helper. No helper binary is bundled; the app verifies the installed executable against OpenAI’s Apple signing team before launching it.

Disconnect stops further polling, requests logout, closes the helper, and removes only the isolated `auth.json` without reading it or following a symlink. An unlink failure is reported. Existing Codex authentication is unaffected. Provider access can also be revoked in the account. Approved connections resume after app relaunch/wake; no interactive login starts automatically. System sleep stops the helper.

## Evidence and limits

Protocol/schema checked against installed **codex-cli 0.162.0-alpha.17.2** on 2026-10-20. Other versions may fail closed and require an updated supported Codex app. Synthetic probes cover strict numeric parsing, expiry/staleness, bucket selection, official login URL validation, RPC allowlisting, disconnection races, isolated-store ownership/symlinks, panel-only quota/menu isolation and four-language fixed panel bounds. A separately approved live device-code login, account quota response and weekly-window rendering were also verified on this Mac on 2026-10-20. The account returned only a secondary weekly window; the UI centers that single row and does not invent a primary window. Other plans, future CLI versions and reset/restriction recovery remain subject to their returned data. Synthetic previews use example values, not captured account data.

Official references: [Codex app-server](https://learn.chatgpt.com/docs/app-server), [direct Sign in with ChatGPT](https://developers.openai.com/siwc/token-sharing-open-source/sign-in), [SIWC Codex bridge](https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server).

Daily-statistics verification (2026-10-20): after separate user approval, the installed app read real service buckets. Missing dates stayed unknown and quota stayed connected. The graph from the initial implementation has since been removed. Numeric summaries, consent routing, independent local records, invalid/conflicting dates, true zero, freshness, five-minute cadence and late replies after disabling are covered by synthetic probes. Documentation previews contain example values only.

Local record reading remains in Mac Thermal Settings directly below Language. Local UTC-today totals, counts, composition and model TOP 3 include `codex-auto-review` alongside other models. Validated cumulative deltas attribute tokens to each model without double counting. Account statistics remain the whole-account values supplied by OpenAI and cannot be filtered using this Mac's local records.

When signed out or re-authentication is required, account cards show a sign-in message/action instead of cached data. Connected users without daily-statistics consent see the separate review action. Pending connections have no duplicate action; missing-helper/network states offer connection management. No developer-operated collection endpoint or remote analytics is used; see [Security](../SECURITY.md) for local persistence exceptions.

## Extended insights

The fixed 300×420 panel restores its original title, runtime, account button and connection badge header. The header and footer stay fixed. Quota is the first card inside the same scrolling body as today, composition, models and account summaries; it no longer floats above the scroller. Its body scrolls vertically, reserving room for macOS always-visible scrollbars. The initial viewport shows today, token composition and local model TOP 3 together. Clicking a model row expands that model’s composition immediately below the ranking.

The local composition card shows input/output tokens, cached-input reuse and reasoning-output share. Cache is a subset of input and reasoning a subset of output; neither is added twice. Blue input and violet output values correspond to the thin composition strip. Below the model ranking, account cards group lifetime/peak tokens, streaks and longest turn, followed by seven-day total/mean/peak date/coverage. Missing dates are excluded from means and today may be incomplete. There is no ten-minute record aggregation or daily graph rendering. No new file scope, timer or network method is added.

A separate default-off `codexAccountSummaryApprovedV1` review permits `lifetimeTokens`, `peakDailyTokens`, `currentStreakDays`, `longestStreakDays` and `longestRunningTurnSec` from the existing response. Values are optional validated integers retained only in memory. Summary off clears these fields while daily statistics stay connected; daily-statistics off and account disconnect also clear summary approval. Existing daily-statistics approval never silently enables summary display. No developer backend, analytics SDK, remote logging or usage-history file is introduced.
