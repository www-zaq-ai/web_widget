# Phoenix host integration

`web_widget` is a dependency of the host application. The host supplies connector configuration, trusted shared-protocol constructors, a config-bound sink callback, its PubSub server, and the serving endpoint with the package's scoped LiveView socket. ZAQ owns routing, permissions, identity resolution, and durable conversations. The package owns iframe delivery, signed identity verification, page binding, browser state, and host response delivery to the correct widget. It has no compile-time ZAQ dependency.

## Explicit supervision and configuration

The OTP dependency starts required libraries, including Mnesia, but **no widget
processes or listeners**. Do not disable its dependencies with `runtime: false` or
`app: false`. Add this child to your host supervisor before connector runtimes:

```elixir
children = [
  {Phoenix.PubSub, name: MyHost.PubSub},
  {WebWidget,
   pubsub_server: MyHost.PubSub,
   authentication: [replica_nodes: [node()]],
   transport: [endpoint: MyHostWeb.Endpoint, widget_path: "/widget", scheme: :https]},
  MyHost.ConnectorSupervisor,
  MyHostWeb.Endpoint
]

Supervisor.start_link(children, strategy: :rest_for_one, name: MyHost.Supervisor)
```

Declare the same intended replica list on every distributed node, including the
local node; `[node()]` above is a single-node deployment example, not cluster
discovery. Multi-node deployments pass all intended node atoms. Environment
variable naming/parsing is entirely the host's choice. The endpoint can start
after infrastructure; readiness stays non-green until it is actually serving.

There is one infrastructure instance per BEAM node. Duplicate starts fail with
`{:already_started, pid}`. Init options are validated before children start and
invalid input returns `{:invalid_widget_configuration, field, explanation}`.
Configuration is immutable for that running instance, never copied into global
application environment. Replace infrastructure to change it, then rebuild
connector children. Runtimes stop when their configuration owner stops, and
sessions/readiness are fenced by generation even before monitor delivery.
Use host supervisor ordering/rebuild logic so connector runtimes restart only
after infrastructure; do not keep an old `build/2` child spec across replacement.
Local shutdown does not stop Mnesia or erase shared authentication state.

| Init option | Default / ownership |
| --- | --- |
| `pubsub_server` | Required host-owned response PubSub name; never started by infrastructure |
| `identity_verifier` | `:connector_key`, or a trusted verifier MFA |
| `authentication.token_ttl_seconds` | `604_800` |
| `authentication.refresh_lead_seconds` | `300`; must be less than token lifetime |
| `authentication.first_binding_window_seconds` | `5` |
| `authentication.control_proof_ttl_seconds` | `30` |
| `authentication.replica_nodes` | Required on distributed nodes; `[node()]` only when non-distributed |
| `transport.endpoint` | Unset; readiness remains unverifiable until configured |
| `transport.widget_path` | `"/widget"`; must match router/socket mounts |
| `transport.scheme` | `:http`; selects an actual local listener, not a public proxy scheme |
| `transport.tls_options` | `[]`; only verified `cacertfile` / `cacerts` |
| `public_url` / `token_url` | Optional public origin / authenticated same-origin token path |
| `response_diagnostics` | `false`; `true` or `:summary` opt in |

All authentication timings are positive integer seconds. Membership must be
nonempty, unique node atoms containing the local node. Startup configures no
host endpoint, TLS certificates, routes, cookie policy, connector, or listener.

### Migration from automatic startup

- Replace `start_web_server` / `start_integration_server` with explicit children.
- Move `config :web_widget, :authentication` into `authentication:` init options.
- Move trusted `:integration` values into init options; move nested `readiness:`
  and `widget_path` into `transport:`. Global settings no longer affect consumers.
- Use `RuntimeBuilder.build/2` and `embed_script/2` against running infrastructure.
  `build/3` remains an explicit construction-only compatibility bridge; it never
  changes running options. Installing its child rejects providers that differ from
  the running infrastructure. It is not a per-connector configuration override.
- Keep ordinary Phoenix endpoint configuration (including `web_widget_session`,
  PubSub for sockets, listener addresses, TLS, and signing secrets) with its owner.
- For the local demo use `mix demo`, which explicitly starts `WebWidget.Standalone`.
- For package-endpoint deployments explicitly supervise
  `{WebWidget.Standalone, mode: :package, infrastructure: widget_opts}`. This starts
  the package endpoint and local socket PubSub, but no Repo or demo. Set
  `transport: [endpoint: WebWidgetWeb.Endpoint, ...]` in `widget_opts` if overriding
  transport defaults. Response PubSub may still reference the existing host server.
- Standalone without a mock runtime can explicitly supervise
  `{WebWidget.Standalone, infrastructure: widget_opts}`; development/test demos
  add `demo: [allowed_domains: [...], multiple_conversations: false]`.

### Routes and assets

Add a released Git tag to the host's Mix dependencies and run `mix deps.get`:

```elixir
{:web_widget, git: "https://github.com/www-zaq-ai/web_widget.git", tag: "vX.Y.Z"}
```

Git dependency installs use the bundle committed in the tag; they do not fetch release attachments.

Mount the widget outside the host browser/authentication pipeline: the macro installs its own scoped session, LiveView flash, CSRF and secure headers. Do not fetch the BO session first. Backend controls remain separate and stateless; each request carries a strict signed backend proof.

```elixir
import WebWidget.Router

scope "/" do
  web_widget("/widget")
end

scope "/" do
  pipe_through :api
  web_widget_api("/widget-api")
end
```

Add the matching socket mount to the host endpoint, leaving BO's `/live` and session configuration unchanged:

```elixir
import WebWidget.Endpoint
web_widget_socket("/widget")
```

Each iframe uses only `/widget/:widget_id/live` (WebSocket or the existing long-poll fallback). Its HttpOnly, host-only `_web_widget_session` cookie has Path `/widget/:widget_id`, and uses package-specific signing options. Signed widget ID and mount path are verified at socket connection and connected page mount. Normal CSRF and socket origin checks remain enabled. Mount `web_widget` outside other authenticated `live_session` blocks; its macro creates its own. `allowed_domains` controls iframe parent origins separately.

`web_widget_socket/1` also wraps endpoint request handling to reject ambiguous
duplicates of the reserved cookie name before HTTP or socket parsing. Do not bypass
that wrapper in a custom endpoint `call/2`; delegate through `super/2`.
The rejection does not affect BO routes or unrelated duplicate cookie names.

Initial bootstrap may replace a single unusable/cross-widget cookie with fresh
anonymous CSRF state; it never carries over identity or conversation state.
Verification is read-only. Each iframe document initializes at most once, permits
at most three read-only resynchronizations, and allows ten seconds for bootstrap
plus LiveView establishment or each transient reconnect. Transport opens cannot
reset those limits. Failure shows an unavailable message and requires explicit
reload; identity renewal and authorized conversation restoration stay separate.
Backend revocation stops transport recovery without relabeling it as a session failure.

For a nested/custom router mount such as `/support/chat`, register `web_widget_socket("/support/chat")` on the endpoint and set trusted integration `widget_path: "/support/chat"`. The returned `RuntimeBuilder.embed_script/2` snippet includes `data-widget-url="https://PUBLIC-ORIGIN/support/chat/42"`; the loader honors that URL and the iframe renders the corresponding socket URL. All three prefixes must match.

The `web_widget/1` macro serves `/web_widget/assets/*path` directly from the dependency's `priv/static/assets`, using `WebWidget.Static` as a route. Released Git tags include the tracked production bundle. The host needs no Node installation, asset copy/build task, static-path allowlist entry, or endpoint static plug. Do not run a second package endpoint when mounting in the host endpoint.

The host-mounted topology uses the host endpoint for `/widget/:id`, `/widget/:id/live/*`, `/widget-api/:id/disconnect` and `/web_widget/assets`. A separate configuration-only package endpoint supports the same paths. Proxy the widget subtree, including WebSocket upgrades and long polling, to that endpoint; BO's `/live` must not be redirected. Keep one endpoint topology per public URL.

### Cookie policy and migration

Canonical connector `settings["same_site"]` must contain exactly `"None"`, `"Lax"`, or `"Strict"`. Missing, nil, blank and invalid values fail runtime construction. Directly registered runtime widgets must also supply `same_site`. New connector defaults belong to the host; endpoint policy fallbacks are not supported:

```elixir
%{settings: %{"same_site" => "Lax"}}
```

Populate every legacy connector's setting before upgrading, explicitly preserving its previous policy or selecting a new one. Partial edits must preserve that stored value. `WebWidget.Embedding.Session.effective(widget, endpoint, scheme)` resolves the widget policy, Secure flag and source, or a fixed configuration failure. It is not a transport readiness probe: #16 must verify host mounting before reporting a policy as applied; old/unverified adapters remain unknown. HTTPS forces Secure for every policy, including when partitioning is disabled and `secure: false` is configured. None requires HTTPS. HTTP development uses explicit Lax/Strict and does not silently downgrade None. Trust only correctly configured TLS termination/proxy scheme handling.

Widget transport cookies carry `Partitioned` by default for all SameSite policies.
Partitioning forces Secure and requires HTTPS, even if the host specifies `secure: false`.
This technical option belongs only to the host endpoint, not connector settings:

```elixir
# HTTP development only; retain normal Secure/SameSite rules when disabled.
config :my_host, MyHostWeb.Endpoint,
  web_widget_session: [partitioned: false]
```

Initial widget pages do not write cookies. Before connecting, each iframe uses
`<widget-page-path>/session` under a connector-path Web Lock, then performs a
read-only cookie acceptance check. Multiple instances share one transport cookie
within a top-level site; different parent sites use separate partitions. JWT/page
authorization and conversations remain independent. Blocked cookies fail explicitly.

Install the package, endpoint mount, router pipeline, proxy rules and updated generated snippet together. Existing iframe documents using `/live` require reload; changing a connector policy requires runtime replacement and page reload. No BO cookie is rewritten by widget routes. Independently scoped widgets cannot overwrite one another's cookie attributes. Partitioned None supports cross-site embedding on supported browsers even when ordinary third-party cookies are blocked; Lax/Strict still do not support normal cross-site iframe sessions.

### Local readiness

ZAQ may invoke the optional configured adapter callback
`WebWidget.Integration.RuntimeBuilder.status(id, timeout_ms: 2_000)` on the serving
node through its existing NodeRouter action. Configure the serving endpoint explicitly
in host-mounted mode, retaining the other integration options:

```elixir
{WebWidget,
  pubsub_server: MyHost.PubSub,
  identity_verifier: :connector_key,
  transport: [endpoint: MyHostWeb.Endpoint, widget_path: "/widget", scheme: :https]}
```

In explicit package-endpoint composition, the default transport references
`WebWidgetWeb.Endpoint`. Scheme selects an **actual local listener**, default
`:http`; use `:https` for direct TLS. Listener address/port come from the configured
endpoint, not a caller URL. Wildcard addresses are probed through loopback. The
endpoint's `url: [host: ...]` supplies Host, Origin and the verified TLS hostname;
normal socket origin checks stay enabled. Private CAs may be supplied through
`transport: [tls_options: [cacertfile: "/trusted/widget-ca.pem"]]` (or `cacerts`).
Disabling TLS verification is not supported. The probe uses Req for the cookie-free
page, `/session` initialization, and a read-only `/session?verify=1` round trip with
its anonymous cookie. It uses the verified JSON CSRF token, not the page meta token,
for the Mint (already used by Req) HTTP/1.1 WebSocket upgrade, then closes without
joining a LiveView or issuing/consuming identity credentials. All steps share the
original total deadline. No user cookie jar or browser coordination lock is used.

The version-1 response contains five checks and only allowlisted effective settings;
see [adapter contract](adapter-contract.md#adapter-readiness-version-1). Cookie and
CSRF probe values, signing keys, callbacks, private configuration and raw failures
never leave the checker. Connector-key identity reports the installed connector
values. A custom verifier's opaque identity policy stays unresolved. Effective
SameSite is connector-owned and reported only after verification of the scoped
bootstrap cookie and socket. Endpoint inheritance is not supported. Partitioned,
Secure, HttpOnly, host-only and path attributes must match the installed policy;
neither the page nor the verification read may write a widget cookie. HTTP-only
development endpoints must explicitly configure `web_widget_session: [partitioned: false]`.

Response-delivery checks cover the installed Phoenix PubSub registry, running
supervision tree and local PG2 membership, without subscribing or broadcasting.
Unsupported custom PubSub adapters report unknown rather than assumed readiness.
These checks do not establish availability of remote PubSub nodes.

Zero visitors can be ready. No new listener, connector endpoint process or browser
connection is introduced. Results are intentionally uncached: endpoint-wide listener
lookups are cheap; per-widget handshakes must reflect its current runtime/policy.
Runtime generation and listener identity are rechecked before a positive result.
Without authoritative lifecycle evidence the checker reports unavailable/unknown,
not a guessed starting state. Caller input accepts only a positive integer ID and
an optional 1–2,000 millisecond total timeout.

Readiness is local evidence, not proof that a public reverse proxy forwards widget
upgrades or that browsers accept third-party cookies. A TLS-terminating proxy with
only a local HTTP listener cannot obtain a green partitioned or None/Secure check through an HTTPS
`public_url` alone. Until its serving HTTPS/session path can be verified, keep that
deployment non-ready and verify the external proxy path separately; never spoof
forwarded headers or weaken CSRF/origin/TLS checks to make the probe pass. Preserve
the HTTPS cross-site connect/reconnect deployment tests alongside local readiness.

## Runtime builder and shared protocol

The resolved connector must include string-keyed settings
`%{"identity_issuer" => "zaq_issuer", "identity_audience" => "zaq_audience"}`.
ZAQ supplies these new-connector defaults; sign tokens with the actual configured
values. Identifiers must be exact UTF-8 strings of 1–255 bytes without surrounding
whitespace. Missing or invalid settings fail construction; integration options
provide no fallback. Upgrade existing connectors atomically before installing this
version. Editing either identifier requires a host runtime rebuild, invalidates
old sessions and rejects tokens with old claims.

Register `WebWidget.Integration.RuntimeBuilder` as the `web_widget` channel runtime builder. The host's existing supervisor owns its child lifecycle. One enabled connector corresponds to one package runtime and a positive integer connector ID. The string form is the public widget route ID. The builder reads the host's resolved connector key privately; no key appears in public widget configuration or the installation snippet.

```elixir
{WebWidget,
  pubsub_server: MyHost.PubSub,
  identity_verifier: :connector_key,
  token_url: "/api/widget-token"}
```

The package also accepts a trusted custom verifier MFA for browser identity, but the signed backend disconnect route is available only with connector-key verification. The verifier receives `(proof, %{widget_id: string_id, channel_config_id: integer_id, page_id: signed_socket_id})` after any configured prefix arguments and returns `{:ok, %{sender_id: external_id, expires_at: unix_seconds}}` or an error. Conversation and prompt metadata are supplied later through `zaq.widget.updateContext`, never through JWT identity or verifier output.

`RuntimeBuilder.build/2` returns `{:ok, {runtime_child_spec, []}}`. Trusted hooks provide `message`, `command`, `context`, `delivery`, `response`, and `sink_mfa` constructors. The package calls `sink_mfa` in the caller with a constructed payload and server-owned context. The host routes messages, authorizes resume/history, persists conversation state, and publishes `{:web_response, adapter_event_name, shared_response}` to the private delivery topic. The package subscribes before the first question, checks request/conversation/message correlation, and forwards public `response.*` events to its React UI. No second browser WebSocket, SSE, AG-UI, or compile-time host dependency is needed.

For an integrated connector, the installer emits a public script containing the widget ID and the optional `token_url` attribute from integration configuration. The embedding website supplies that authenticated same-origin endpoint and may use:

```html
<script src="https://ZAQ-HOST/web_widget/assets/embed.js"
        data-widget-id="42" data-widget-url="https://ZAQ-HOST/widget/42"
        data-token-url="/api/widget-token" defer></script>
```

`iframe-location-id="#my-widget-container"` selects an existing div with a parent-supplied height. If that div is `#zaq-widget`, the iframe ID is `#zaq-widget-frame`; otherwise it is `#zaq-widget`. `stylesheet-url` is a parent-supplied HTTP(S) CSS URL, handled by the validated postMessage handshake. Neither stylesheet nor presentation settings belong in JWT identity. See [styling](styling-guideline.md) and the [website guide](integration-guideline.md).

## Authentication state and deployment

Set infrastructure `authentication:` init options with a seven-day `token_ttl_seconds` (or another value longer than renewal lead), five-second `first_binding_window_seconds`, five-minute `refresh_lead_seconds`, 30-second `control_proof_ttl_seconds`, and explicit `replica_nodes`. Each configured node must agree on membership. The package uses replicated majority-protected Mnesia RAM tables for page bindings, control idempotency, user revocation cutoffs, and reset metadata. A minority fails closed. A restart rejoins surviving state; complete RAM loss establishes a new cutoff only at quorum. No host SQL migration is needed. Tokens issued in the reset/cutoff second may need retry in the next second.

The initial JWT is bound to the signed Phoenix `socket.id` before conversation initialization. Subsequent checks gate dispatch and response application. In-place renewal preserves the same sender, widget, page, subscription, active stream, draft, and settings. A normal LiveView reconnect uses the same bound token. A full iframe reload needs a new token. The parent client fetches fresh tokens and schedules renewal from server metadata. On store unavailability it waits for authority to recover; backend disconnect is terminal for that iframe.

`web_widget_api("/widget-api")` mounts `POST /widget-api/:widget_id/disconnect`. The backend sends JSON `{"user_id":"..."}` and `Authorization: Bearer <control JWT>`. The JWT has strict `iss`, `aud: identity_audience <> ":control"`, `op: "disconnect"`, numeric `widget_id`, `user_id`, integer `iat`/`exp`, and random `jti`; validity is at most 30 seconds. The request nonce is idempotent in Mnesia. The cutoff commits before a scoped PubSub broadcast; matching LiveViews unsubscribe, notify their parent, display the refresh message, and close transport. A browser JWT cannot authorize this operation. See [authenticated chat](authenticated-chat.md) for issuance examples.

Exact allowed HTTP(S) parent origins determine the CSP `frame-ancestors` policy and parent postMessage acceptance. Missing or empty origins deny embedding, including same-origin. Missing/stopped runtimes render an unavailable view. Connector replacement invalidates previous runtime sessions; new mounts resolve the current runtime.

## Build and release assets

Dependency configuration files are not imported by Phoenix. Starting the OTP
dependency starts no widget services. Explicitly supervise the infrastructure
child as described above; do not enable legacy startup flags.
Widget rendering explicitly disables React SSR; no Node SSR service
or global LiveReact setting is needed.

Release Please opens a version and changelog PR from conventional commits. Merging
it creates the `vX.Y.Z` tag and GitHub Release and updates the Mix project version.
GitHub Actions installs JavaScript dependencies with `npm ci`, runs the existing
Vite build, checks that all compiled files match the tracked bundle, and attaches
the bundle archive to the release. The assets must be committed with frontend
changes, since Git dependencies receive the tag contents rather than attachments.
When assembling a host release, retain the dependency's `priv/static/assets`
directory. Static responses revalidate with ETags.

Embed `/widget/<connector-id>` on a configured allowed origin. The existing
[website examples](../README.md#add-the-widget-to-your-website) demonstrate the
embed script, readiness, settings and resizing. The
[signed bootstrap guide](authenticated-chat.md) covers backend proof issuance
and the configuration needed before real ZAQ use.

## Verification

Run `mix assets.build`, `mix test`, and `mix precommit` in this repository. Run Chromium Playwright tests in `assets/` with the installed browser. The package also provides `test/support/integration/shared_protocol_smoke.exs` for the pinned sibling ZAQ constructor contract and host mounted asset smoke scripts under `test/support/integration/`. These checks do not call a live agent/model; a final deployment smoke should exercise its real token endpoint, first question, authorized resume, renewal, and backend disconnect.
