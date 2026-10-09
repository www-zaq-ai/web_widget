# Phoenix host integration

`web_widget` is a dependency of the host application. The host supplies connector configuration, trusted shared-protocol constructors, a config-bound sink callback, its PubSub server, and its LiveView socket. ZAQ owns routing, permissions, identity resolution, and durable conversations. The package owns iframe delivery, signed identity verification, page binding, browser state, and host response delivery to the correct widget. It has no compile-time ZAQ dependency.

## Routes and assets

Add a released Git tag to the host's Mix dependencies and run `mix deps.get`:

```elixir
{:web_widget, git: "https://github.com/www-zaq-ai/web_widget.git", tag: "vX.Y.Z"}
```

Git dependency installs use the bundle committed in the tag; they do not fetch release attachments.

Mount the browser widget and backend control routes in separate scopes. The browser scope needs the normal session, LiveView flash, CSRF and secure headers. The API scope needs no browser session or CSRF; each request carries a strict signed backend proof. The control plug can parse its JSON body even when the host endpoint has no general JSON parser.

```elixir
import WebWidget.Router

scope "/" do
  pipe_through :browser
  web_widget("/widget")
end

scope "/" do
  pipe_through :api
  web_widget_api("/widget-api")
end
```

Expose the host's LiveView socket at `/live` with the same `Plug.Session` options used for the widget route. Mount `web_widget` outside other authenticated `live_session` blocks; its macro creates its own. Keep normal socket origin checks. `allowed_domains` controls iframe parent origins separately. The package supplies the widget root layout, LiveView hook and browser bundle.

The `web_widget/1` macro serves `/web_widget/assets/*path` directly from the dependency's `priv/static/assets`, using `WebWidget.Static` as a route. Released Git tags include the tracked production bundle. The host needs no Node installation, asset copy/build task, static-path allowlist entry, or endpoint static plug. Do not run a second package endpoint when mounting in the host endpoint.

ZAQ's local mount uses the existing host endpoint for `/widget/:id`, `/widget-api/:id/disconnect`, `/web_widget/assets`, and `/live`. A separate configuration-only package endpoint is supported for deployments that proxy all four paths to it; keep one endpoint topology per public URL.

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
config :web_widget, :integration,
  pubsub_server: Zaq.PubSub,
  identity_verifier: :connector_key,
  token_url: "/api/widget-token"
```

The package also accepts a trusted custom verifier MFA for browser identity, but the signed backend disconnect route is available only with connector-key verification. The verifier receives `(proof, %{widget_id: string_id, channel_config_id: integer_id, page_id: signed_socket_id})` after any configured prefix arguments and returns `{:ok, %{sender_id: external_id, expires_at: unix_seconds}}` or an error. Conversation and prompt metadata are supplied later through `zaq.widget.updateContext`, never through JWT identity or verifier output.

`RuntimeBuilder.build/2` returns `{:ok, {runtime_child_spec, []}}`. Trusted hooks provide `message`, `command`, `context`, `delivery`, `response`, and `sink_mfa` constructors. The package calls `sink_mfa` in the caller with a constructed payload and server-owned context. The host routes messages, authorizes resume/history, persists conversation state, and publishes `{:web_response, adapter_event_name, shared_response}` to the private delivery topic. The package subscribes before the first question, checks request/conversation/message correlation, and forwards public `response.*` events to its React UI. No second browser WebSocket, SSE, AG-UI, or compile-time host dependency is needed.

For an integrated connector, the installer emits a public script containing the widget ID and the optional `token_url` attribute from integration configuration. The embedding website supplies that authenticated same-origin endpoint and may use:

```html
<script src="https://ZAQ-HOST/web_widget/assets/embed.js"
        data-widget-id="42" data-token-url="/api/widget-token" defer></script>
```

`iframe-location-id="#my-widget-container"` selects an existing div with a parent-supplied height. If that div is `#zaq-widget`, the iframe ID is `#zaq-widget-frame`; otherwise it is `#zaq-widget`. `stylesheet-url` is a parent-supplied HTTP(S) CSS URL, handled by the validated postMessage handshake. Neither stylesheet nor presentation settings belong in JWT identity. See [styling](styling-guideline.md) and the [website guide](integration-guideline.md).

## Authentication state and deployment

Set `config :web_widget, :authentication` with a seven-day `token_ttl_seconds` (or another value longer than renewal lead), five-second `first_binding_window_seconds`, five-minute `refresh_lead_seconds`, 30-second `control_proof_ttl_seconds`, and explicit `replica_nodes`. Each configured node must agree on membership. The package uses replicated majority-protected Mnesia RAM tables for page bindings, control idempotency, user revocation cutoffs, and reset metadata. A minority fails closed. A restart rejoins surviving state; complete RAM loss establishes a new cutoff only at quorum. No host SQL migration is needed. Tokens issued in the reset/cutoff second may need retry in the next second.

The initial JWT is bound to the signed Phoenix `socket.id` before conversation initialization. Subsequent checks gate dispatch and response application. In-place renewal preserves the same sender, widget, page, subscription, active stream, draft, and settings. A normal LiveView reconnect uses the same bound token. A full iframe reload needs a new token. The parent client fetches fresh tokens and schedules renewal from server metadata. On store unavailability it waits for authority to recover; backend disconnect is terminal for that iframe.

`web_widget_api("/widget-api")` mounts `POST /widget-api/:widget_id/disconnect`. The backend sends JSON `{"user_id":"..."}` and `Authorization: Bearer <control JWT>`. The JWT has strict `iss`, `aud: identity_audience <> ":control"`, `op: "disconnect"`, numeric `widget_id`, `user_id`, integer `iat`/`exp`, and random `jti`; validity is at most 30 seconds. The request nonce is idempotent in Mnesia. The cutoff commits before a scoped PubSub broadcast; matching LiveViews unsubscribe, notify their parent, display the refresh message, and close transport. A browser JWT cannot authorize this operation. See [authenticated chat](authenticated-chat.md) for issuance examples.

Exact allowed HTTP(S) parent origins determine the CSP `frame-ancestors` policy and parent postMessage acceptance. Missing or empty origins deny embedding, including same-origin. Missing/stopped runtimes render an unavailable view. Connector replacement invalidates previous runtime sessions; new mounts resolve the current runtime.

## Build and release assets

Dependency configuration files are not imported by Phoenix. The application
starts only its runtime registry by default, without the standalone endpoint,
Repo or demo runtime. Do not enable `config :web_widget, start_web_server: true`
in the host. Widget rendering explicitly disables React SSR; no Node SSR service
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
