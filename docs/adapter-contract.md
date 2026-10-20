# Web Widget Adapter Contract

## Status and source of truth

The submission/message lifecycle migration (2026-10-12), coordinated with
[ZAQ PR #836](https://github.com/www-zaq-ai/zaq/pull/836), selects shared web protocol
**version 2**. Version 1 responses are explicitly unsupported; this is a coordinated
host/package upgrade, not an automatic compatibility fallback. ZAQ's published
constructors own the host protocol. This document owns the widget's
integration decisions and presentation mapping, not a second shared schema.

The package implements the milestone 2 authenticated chat path and the issue #14
authentication and cluster decisions below. Host deployment still requires the
matching token endpoint, router macro, and Mnesia membership configuration.
The historical [implemented delivery boundary](#implemented-delivery-boundary)
records earlier migration evidence. The [wiring plan](exec-plans/wiring-widget.md)
tracks its original acceptance work.

## Responsibilities and boundary

`web_widget` owns iframe delivery, parent postMessage validation, server-side
verification of parent identity/session, subscription authorization, LiveView
browser state and assistant-ui presentation. It translates widget actions using
host-supplied constructors and encodes public responses for its UI.

ZAQ owns connector configuration and lifecycle, People identity resolution,
conversation ownership and durable history, permissions, routing, agent selection,
and shared Message/Command admission through WebBridge and existing role dispatch.
The widget does not call Engine or construct Incoming/Outgoing directly.

ZAQ depends on `web_widget`; the package has no compile-time dependency on ZAQ
internals. Constructor inputs and UI events are plain maps. Host-supplied
constructors produce shared boundary values consumed through trusted runtime
hooks, without `%Zaq.*{}` struct literals in the package. ZAQ never constructs
`WebWidget.*` structs. This replaces the earlier plain-map-only callback decision.

## Runtime integration

### Public host adapter (PR #24 / issue #23)

Generic hosts register `WebWidget.HostAdapter`. Its public callbacks are:
`infrastructure_child_specs(host_opts) -> {:ok, [OTP child specs]}`,
`build_runtime_specs(config, hooks) -> {:ok, {state_spec_or_nil, listeners}}`,
`ingress_status(config, opts \\ []) -> {:ok, channel_status_map}`, and
`installation(config_or_id, base_url, opts \\ []) -> {:ok, snippet}`.
Verified sender enrichment travels as a trusted Context option;
see [verified sender profiles](#verified-sender-profiles).
Construction errors are redacted. Infrastructure specs represent the shared
singleton, never connector children. Runtime specs carry the independent connector
supervisor; recovery remains inside that stable connector, not in host coordination.

Host hooks contain only `message`, `command`, `context`, `delivery`, `response`
constructors and the fixed config-bound `sink_mfa`. The adapter derives widget identity from
`config.id` and presentation from string-keyed `config.settings` (`display_name`
falls back to `config.name`). Generic host bridges do not construct widget hooks.
Raw `WebWidget.Connector` retains its explicit widget hook API for compatibility.

Infrastructure `proxy: [trusted_proxies: [ip_tuple, ...], public_origin: https_origin]`
and `session: [partitioned: boolean, secure: boolean, endpoints: [{EndpointModule,
[partitioned: boolean, secure: boolean]}]]` are authoritative process
options alongside PubSub, authentication membership and transport settings. Proxy
defaults to disabled; session defaults to partitioned with HTTPS-forced Secure.
No widget policy is read from endpoint configuration or copied to package env.
Normal Phoenix endpoint listener, URL, signing secret, TLS and routing remain
host-owned. Never infer proxy trust from forwarding headers or membership from
connected nodes. Scope normalization applies only to mounted widget HTTP/socket
paths, and normal proxy-terminated HTTPS remains supported.

The adapter owns bounded readiness, desired-versus-installed comparison, safe
channel status projection and installation defaults/validation. Channel status
uses `:ok`, `:pending`, `:error`, `:unknown`, `:disabled` with mode `"websocket"`
and closed safe reasons/checks/settings/verification; readiness does not expose
credentials, hooks or raw failures. `RuntimeBuilder.status/2` deliberately remains
the raw package version-2 compatibility observation, not the generic host boundary.

### Trusted deployment mount scope (PR #24)

Top-level infrastructure `scope: "/channels"` is a trusted process option,
normalized once at init. Omitted scope or explicit `"/"` preserves root mounting.
A trailing slash is normalized; relative/empty/non-string paths, repeated slashes,
dot segments, percent encoding, query/fragment, whitespace and backslashes reject
startup with a fixed redacted configuration error. It is not a connector setting,
browser parameter or endpoint policy.

A non-root scope derives every package path: `/channels/widget/:widget_id`,
its `/session` and `/live/*`, `/channels/widget-api/:widget_id/disconnect`, and
`/channels/web_widget/assets/*`. Router/endpoint mounts are compiled, so hosts
must use the same scope in `web_widget("/widget", scope: "/channels")`,
`web_widget_api("/widget-api", scope: "/channels")` and
`web_widget_socket("/widget", scope: "/channels")`, outside an additional Phoenix
path scope. Arity-1 calls remain root/legacy compatible. A scoped macro accepts
its default prefix or its exact fully-derived prefix without doubling; any other
scoped prefix rejects compilation. Scope/path inconsistency fails init when an
explicit endpoint supplies authoritative mount metadata; otherwise requests fail
closed and readiness cannot be green. Runtime configuration never relocates routes.

Legacy custom `transport.widget_path` is retained for root deployments. With
non-root scope it may be omitted or exactly equal the derived widget prefix;
conflicts reject instead of choosing precedence. Online installation `[]` uses
the running scope; offline `installation(id, base_url, scope: "/channels")` uses
the same validated path rules. An online scope/path override cannot contradict
the running mount. Origins remain root HTTP(S) origins. No host asset copy or
rewrite is needed; layouts, static serving, probes and scoped cookies agree.
Callback signatures and the exact six-key constructor/sink hooks are unchanged.

### Explicit infrastructure lifecycle (issue #23)

The embedding host starts `{WebWidget, opts}` once in its supervisor. The OTP
dependency starts required library applications (including Mnesia), but no widget
services, endpoint, Repo, or demo runtime. Infrastructure is a singleton per BEAM
node: its configuration owner, runtime registry and binding store have fixed names.
Duplicate starts fail; multi-instance startup is not supported.

Init options are the sole source of infrastructure authentication, trusted
integration and transport/readiness overrides. Serving endpoints/listeners may be
discovered from running endpoints bearing the package socket metadata. The startup boundary validates and
normalizes them, applying package defaults. No options are copied into application
environment. A configuration snapshot belongs to one infrastructure generation;
stopped or replaced generations cannot authorize sessions or report ready. The
infrastructure uses `:one_for_all`: a configuration-owner, registry or binding-store
crash replaces the local infrastructure generation without resetting shared tables.

Start host PubSub before widget infrastructure, and infrastructure before connector
runtimes. The host owns endpoints, mounting, TLS, routing, and connector lifecycle.
Infrastructure references the existing endpoint; it never starts or reconfigures
it. Hosts supervise `{WebWidget.Connector, config: config, hooks: hooks}` independently
of the infrastructure restart domain. The child specification carries host inputs,
not a preconstructed runtime. Each connector owns runtime construction and bounded
recovery after whole-infrastructure or internal-child replacement. Operational
access is generation-fenced immediately; old runtime/session references never revive.
The host owns creation, replacement and removal, not package-specific recovery.
Infrastructure retains no connector inputs and cannot resurrect removed children.

Stopping local infrastructure makes binding-store operations fail closed without
stopping shared Mnesia or deleting tables, revocations, replay entries, or reset
metadata. Local restart rejoins surviving shared state; quorum and full RAM-loss
reset semantics remain unchanged. Membership is explicit on distributed nodes;
the existing non-distributed single-node default is retained.

Standalone/demo and package-endpoint deployments explicitly compose PubSub,
infrastructure, endpoint and optional demo children in their own supervisor using
the same API. Legacy automatic-start flags and global authentication/integration
settings no longer select startup or runtime behavior; migrate them to init
options. Endpoint configuration remains the endpoint owner's responsibility.

Use the existing channel lifecycle and BridgeSupervisor. The provider entry in
ZAQ's existing Channels map is:

```elixir
web_widget: %{
  bridge: Zaq.Channels.WebBridge,
  adapter: WebWidget.HostAdapter
}
```

`WebWidget.Connector.child_spec/1` returns a standard supervisor child specification.
`start_link/1` validates `config:` and `hooks:` and starts a connector subtree, even
when infrastructure is temporarily absent. A connector reserves its node-local ID
throughout recovery, independently of the replaceable runtime registry. Invalid
inputs fail with redacted errors. Hosts may use an ordinary DynamicSupervisor and
terminate/replace the connector child using its returned PID. They must migrate
from preconstructed runtime specifications; public builder construction APIs are removed.

Hooks supply `widget_id = config.id`, presentation settings, the shared
`message`, `command`, `context`, `delivery`, `response` modules, and the
config-bound `sink_mfa`. They do **not** supply a PubSub server. For this host,
the adapter receives `Zaq.PubSub` through validated infrastructure init options.
`{WebWidget, opts}` supplies `pubsub_server` and `identity_verifier`
(a trusted MFA or the default `:connector_key`). Connector construction is private
and always reads current infrastructure providers.
Neither connector settings nor browser input may select
these providers.

Connector-key verification requires both canonical string keys
`config.settings["identity_issuer"]` and `config.settings["identity_audience"]`.
Each must be valid UTF-8, 1–255 bytes, with no leading/trailing whitespace. Missing,
nil, blank and invalid values reject runtime construction with
`:invalid_identity_config`. There are no adapter defaults or integration-option
fallbacks: ZAQ supplies new-connector defaults `zaq_issuer` / `zaq_audience` and
enforces the atomic configuration upgrade for existing connectors. Trusted custom
verifier MFAs retain their own policy and do not use these connector-key settings.

The builder binds the resolved connector key and exact identifiers privately into
the existing verifier, and derives the backend audience as
`identity_audience <> ":control"`. Changing either value requires a host-owned
connector replacement; old sessions lose runtime-generation authorization and proofs
with the old claims are rejected. Desired settings alone do not change an installed
runtime. Readiness reports installed values, never a copy of desired host settings.

One persisted connector identifies one widget. Keep its positive integer ID in
Context/Delivery and use its string form in the registry and `/widget/:widget_id`.
Do not persist a separate `widget_id` setting. Host settings are `display_name`,
`allowed_domains` (exact HTTP(S) origins). Stylesheets are not connector settings
or runtime hooks. The host shared command supports validated stylesheet params,
but this adapter does not accept them through browser initialization. The optional
embed script attribute `stylesheet-url` instead controls browser-only presentation.
The loader resolves relative URLs against the parent document and sends an absolute
HTTP(S) URL over the existing postMessage channel on each ready handshake. The
iframe validates the parent source, allowed origin and URL before adding one link
to its head. Credentials and non-HTTP(S) URLs are rejected. Omitting the attribute
uses bundled styles; runtime `stylesheet_url` no longer supplies a stylesheet.
This presentation message does not change signed identity, settings or host commands.
Theme and language remain parent-owned. Start with `multiple_conversations: false`;
   ZAQ does not provide the current widget's eager conversation-list contract.

The local ZAQ install mounts the package router on its existing endpoint.
Released Git tags contain the built bundle in `web_widget/priv/static/assets`.
The `web_widget/1,2` router macro serves those files at `<scope>/web_widget/assets/*path`
from the dependency itself. ZAQ does not copy or build assets, change its static
path allowlist, or add `WebWidget.Static` to its endpoint. Its scoped
`/widget/:widget_id/live` socket serves the iframe; BO authentication does not apply to the widget mount.
This supersedes the earlier configuration-only choice for this installation.

For hosts retaining package-endpoint installation, explicitly supervise
`{WebWidget.Standalone, mode: :package, infrastructure: opts}` for the endpoint and its socket
PubSub once, without the Repo/demo. Connector runtimes remain ZAQ-owned and use
`Zaq.PubSub` for responses. The iframe uses this endpoint's scoped LiveView
connection; no additional browser realtime connection is introduced.

`RuntimeBuilder.embed_script(widget_id, base_url)` returns one escaped script tag
with `data-widget-id`. The optional trusted integration `public_url` overrides
the supplied base URL; otherwise the deployment must proxy `/widget`,
`/web_widget/assets` and `/widget/:widget_id/live/*` at the ZAQ base origin to the package endpoint.
Only root HTTP(S) origins are supported. The loader creates a single iframe at
`/widget/<id>` on its own origin and applies the existing layout/client behavior.
The authenticated loader obtains a fresh backend JWT and delivers it in the
iframe fragment; manual mounting remains supported through the connect API. See [host integration](host-integration.md).

The optional script attribute `iframe-location-id` is a CSS selector for an
existing div. Targeted embeds fill that div (the parent supplies its height),
keep both launcher and conversation inside it, and do not lock parent scrolling.
Without the attribute, the existing floating/full-screen layout is preserved.
The parent API remains single-widget. A missing/invalid target fails explicitly;
it never falls back to the body. If the div is `#zaq-widget`, the child iframe is
`#zaq-widget-frame` to avoid duplicate IDs. Otherwise the iframe is `#zaq-widget`.
Manual callers may use `zaq.widget.mount(url, selector)` with the same behavior.

## Widget session isolation (issue #12)

The widget browser pipeline owns a separate signed, HttpOnly, host-only cookie
`_web_widget_session`, scoped to the actual widget page path (including custom
mount prefixes). Its sole LiveView transport is `<widget-page-path>/live`, mounted
with `WebWidget.Endpoint.web_widget_socket/1`; BO retains its existing `/live` and
session options. This supersedes the shared `/live` installation described above.
The widget router must not run inside a pipeline that has already fetched the BO
session. It installs its own session before flash/CSRF handling. Signing salts are
package-specific; signed widget ID and mount path are checked against the socket
request URI and page session. Cookie paths are not authorization boundaries.
The endpoint integration rejects multiple occurrences of `_web_widget_session`
in raw Cookie headers before HTTP or transport cookie parsing. Ambiguous requests
fail without writing cookies; BO paths and cookie names are unaffected.
Unknown widget IDs return a static unavailable response without initializing a
session or connecting LiveView; this is not a missing-policy fallback.

Widget transport cookies are partitioned by default, independently of connector
SameSite policy, and require Secure/HTTPS. Only validated infrastructure process options
may disable partitioning (`session: [partitioned: false]`), for example
for HTTP development. Instances share a connector cookie within one top-level site;
different parent sites have separate partitions. Lax/Strict still prohibit cross-site
iframe transport. Host/BO cookies are unchanged.

Instances of one connector share its transport cookie and CSRF state, never user
identity or conversation state. Initial page responses do not write that cookie.
Before connecting, the iframe obtains its CSRF token from the same-origin
`<widget-page-path>/session` endpoint under a connector-path Web Lock. That endpoint
creates fresh transport/CSRF state when the cookie is absent, invalid or bound to
another widget, and otherwise reads the established
session without rewriting it. A verification read confirms cookie acceptance;
blocked cookies and unavailable coordination fail explicitly with bounded work.
Replacement never copies state or authenticates a user: verified identity tokens
remain authoritative. Verification and socket requests never initialize cookies.
The independently signed LiveView page remains the JWT binding identity. Stable
page, installation and transport URLs do not gain instance IDs or redirects.

Browser locks may be storage-partitioned even where cookies are shared. Only the
initial document bootstrap may initialize a cookie. Transient failures of the initial
session HTTP request retry with capped backoff; each attempt is time-bounded but the
outage has no terminal deadline. Successful session initialization is not repeated on
socket errors. Confirmed cookie rejection or invalid configuration offers explicit reload.
Phoenix owns initial transport connection, reconnection and channel rejoin without
widget deadlines or retry budgets.
The widget observes connectivity for presentation and uses existing authentication and
history restoration after rejoin. Cookie policy changes require a fresh page load.

Canonical `config.settings["same_site"]` accepts exactly `"None"`, `"Lax"`,
`"Strict"`; missing, nil/blank/invalid values reject runtime construction. Every
registered widget must explicitly supply its policy; no endpoint or package
fallback exists. Hosts must populate legacy connector settings before upgrading,
using an explicitly chosen policy. Partial edits preserve the stored value; the
complete resolved configuration must contain it. ZAQ owns new defaults and edits.
HTTPS always requires Secure, including unpartitioned Lax/Strict and an endpoint
`secure: false` setting. None requires HTTPS; HTTP development uses explicit Lax/Strict.
No implicit downgrade, BO cookie rewrite, second iframe connection, or CSRF bypass
is allowed. Policy changes require runtime replacement and a page reload before
reconnecting with a session under the new policy. Third-party-cookie blocking can
still prevent cross-site connection even with None.

The generated host installation script includes the explicit `data-widget-url`,
using the trusted deployment scope (or root legacy `:widget_path`) and public origin.
The iframe renders its scoped transport URL; no JWT enters either URL's query.
Host router, endpoint socket mount, proxy and installation prefix must agree.

## Adapter readiness (version 2)

The configured adapter optionally exposes `status(widget_id, timeout_ms: 2_000)`.
The ID is a positive integer and the timeout is a total budget, capped at 2 seconds.
ZAQ independently bounds invocation and validates the closed response. Old adapters
without this callback remain supported; missing support never means ready.

The response is `{:ok, %{protocol_version: 2, status: state, reason: reason,
checks: checks, effective_settings: settings, verification: verification}}`.
`verification` contains `scope: :local`, `session_handshake: :verified | :not_checked`
and `external_https: :not_checked`. Local readiness never asserts public HTTPS reachability.
Readiness means local feed liveness, not security or public-ingress acceptance.
An HTTP-only feed can be ready with Secure/Partitioned/None policy when the scoped
page and session boundaries respond with the expected cookie-free `503
https_required`, or valid HTTPS redirects to the expected authority and path.
This requires no widget proxy policy, host SSL classification or new startup flag.
The actual listener, matching scoped route/socket mount, installed runtime,
delivery, identity and valid cookie configuration must still be present. Arbitrary
404/500/503 responses, wrong redirects and stale observations never establish readiness.
For a guarded feed, `session_handshake` stays `:not_checked`; `cookie_policy` ready
means valid installed enforcement, not permission to bootstrap an insecure session
or evidence of browser cookie acceptance. Guarded HTTP does not downgrade policy.
All five checks are required, in
order: `runtime`, `transport`, `delivery`, `authentication`, `cookie_policy`.
Each is `%{status: state, reason: reason}`. States are `:ready`, `:starting`,
`:unavailable`, `:unknown`; ready has a nil reason. Overall precedence is
unavailable, unknown, starting, ready; ties use check order.

Fixed reasons are:

| Check | Reasons |
| --- | --- |
| runtime | `runtime_not_registered`, `runtime_unresponsive`, `runtime_starting` |
| transport | `transport_not_listening`, `transport_starting`, `transport_unverifiable` |
| delivery | `pubsub_unavailable` |
| authentication | `identity_not_configured`, `identity_settings_mismatch` |
| cookie_policy | `cookie_policy_unsupported`, `cookie_policy_mismatch`, `secure_cookie_required`, `https_required` |
| any | `check_timeout`, `check_failed` |

Starting reasons mean starting. `transport_unverifiable`,
`cookie_policy_unsupported`, `check_timeout`, `check_failed` mean unknown; other
reasons mean unavailable. Callback failures are
`{:error, :invalid_request | :check_timeout | :check_failed}`.

Effective settings contain only `identity_issuer`, `identity_audience`, and
`same_site`, each `%{value: value, source: source}`. Connector-key identifiers
and SameSite are connector-owned; missing legacy policy must be populated by the
host before upgrading, not inferred from endpoint defaults.
Sources allowed by the protocol are connector/application/default, plus endpoint
for SameSite. Unresolved is `%{value: nil, source: :unresolved}` and cannot be
ready. Custom verifiers without provable effective identity settings are not green.
ZAQ owns comparison against current desired settings, disabled state, NodeRouter
invocation and refresh of both BO surfaces after lifecycle changes.

Readiness checks an explicit serving endpoint override, or the unique running
widget endpoint matching the configured mount. Omitted scheme discovers a unique
actual local HTTP/HTTPS listener; ambiguous endpoints/listeners stay unknown.
Where the listener permits a session handshake it checks the cookie-free page's socket/session
paths, initializes an isolated anonymous cookie via `<widget-page-path>/session`,
and verifies that cookie with `/session?verify=1` without rewriting it. The verified
JSON CSRF token authorizes the widget-scoped WebSocket upgrade; the page's CSRF
meta token is not used. Cookie attributes include the installed Partitioned policy,
which requires HTTPS even for Lax/Strict; explicit unpartitioned HTTP development
is supported without changing connector SameSite or weakening Secure requirements.
It does not join a LiveView channel, authenticate a user, consume a JWT, create a
conversation, require visitors, or start a listener. These ephemeral probe values
never appear in results. A healthy BO `/live` or long-poll transport is insufficient.
Listener observations are endpoint-wide; session/handshake results are widget-specific
and are not retained across calls, avoiding stale green after lifecycle changes.

Supported proxy topology is browser HTTPS/WSS -> trusted reverse proxy -> host HTTP/WS.
Infrastructure owns `proxy: [trusted_proxies: [ip_tuple, ...], public_origin: https_origin]`.
The endpoint retains ordinary Phoenix URL/listener configuration, but never supplies
widget trust or cookie policy. Public proxy origin is explicit at infrastructure init.
The package accepts normalized forwarding headers only
from these exact peer IPs and only for that HTTPS origin, before HTTP and socket
dispatch. The proxy must strip client forwarding headers and overwrite proto/host;
the backend must be private. `X-Forwarded-Port` may be absent only when the
configured root HTTPS `public_origin` uses default port 443 (including explicit
`:443`). In that case the configured authority supplies 443, not another header
or the backend listener. A supplied port must exactly match the configured port;
empty, conflicting, comma-separated and repeated forwarding headers are rejected.
Nondefault HTTPS ports still require a single explicit matching forwarded port.
Trust is based on the immediate connection peer, never `X-Forwarded-For` visitor
addresses. No dedicated widget TLS listener is required.
The package endpoint macro validates forwarding before delegating into the
normal Phoenix endpoint plug pipeline, including endpoint `force_ssl`. Trusted
header conflicts still reject if the incoming connection is already marked HTTPS.
Hosts needing earlier normalization may implement the endpoint callback
`web_widget_normalize/1` installed by `web_widget_socket/1,2`. Its default is the
identity function. The supported endpoint-wide order is host normalization,
widget Proxy, widget CookieGuard, then Phoenix (including socket dispatch and
`force_ssl`). A halted connection stops at each boundary. Hosts do not override
`call/2`. The callback is trusted host code, not automatic forwarding opt-in:
it must validate immediate-peer trust and reject ambiguous forwarding before
rewriting, preserve the physical peer for the widget Proxy, and retain headers
needed by that guard. Merely configuring Phoenix `force_ssl` does not activate
this callback or widget proxy trust.
Any earlier external scheme/host rewriter must enforce the same immediate-peer
trust boundary: stripping headers cannot reconstruct a physical HTTP scheme that
an upstream component already changed. Keep the backend restricted to ingress;
do not fabricate headers or add a global forwarding trust bypass.
Peer filtering here requires configured `proxy:` process options. With proxy
disabled, host-wide `rewrite_on` remains host-owned and is not a replacement for
the widget trust configuration. Do not expose an ingress-only HTTP backend to
untrusted clients, whether or not native endpoint `force_ssl` is enabled.
In this mode local readiness checks the real HTTP listener, widget socket mount,
rejection of insecure widget page/session requests (including HTTPS redirects to
the exact configured origin/path), and the configured Secure/SameSite policy.
It does not manufacture forwarding headers to simulate HTTPS. Its session handshake
is `:not_checked`; cookie-policy readiness means configured enforcement, not observed
browser acceptance. Deployment acceptance must independently verify real HTTPS
bootstrap cookies and WSS upgrades through the proxy. A public URL alone cannot
activate proxy trust or prove TLS. HTTP guarded-feed readiness also works without
this optional proxy block, including with host-managed normalization before the
widget wrapper. The host/infrastructure then owns forwarding trust; readiness
does not duplicate it or inspect `force_ssl` to classify ingress. HTTPS redirect
authority is checked against the optional proxy origin or ordinary endpoint URL
host/public port (default 443), as an expected destination only, never TLS evidence.
Only successful direct-listener session handshakes are `:verified`.
Neither mode proves real-user authentication or browser cookie acceptance.
See [host integration](host-integration.md) for trusted readiness configuration.

## Identity, embedding and parent bootstrap

The authenticated credential is a compact HS256 JWT signed by the parent
backend with the exact UTF-8 connector key. JOSE verifies an explicit HS256
allowlist and JWT type; unsupported headers, algorithms and claims fail closed.
Required claims are positive integer `widget_id`, nonblank `user_id`, `iss`,
`aud`, integer Unix-second `iat` and `exp`, and a random 16–255 character
`jti`. Optional `nbf` is enforced. `conversation_id` and `prompt_context`
are not identity claims. A token has a configurable lifetime, seven days by
default, and `exp` must be after `iat`. Configuration must make the lifetime
longer than the renewal lead (five minutes by default). Tests may use shorter
configured intervals. The signing key never enters browser code. A browser JWT
cannot authorize a backend control operation.

Package authentication configuration uses infrastructure `authentication:` init options
with `token_ttl_seconds: 604_800`, `first_binding_window_seconds: 5`,
`refresh_lead_seconds: 300`, `control_proof_ttl_seconds: 30`, and an explicit
`replica_nodes` list for the Mnesia cluster. The first-binding window is a
deployment constant in production; the time values can be shortened for tests.
Reject invalid configuration at startup, including a token lifetime no longer
than the renewal lead, duplicate replica names, or a node outside the configured
membership. The parent backend signs with matching lifetime and issuer/audience.

The parent script accepts `data-token-url` and optional `iframe-location-id`
and `stylesheet-url`. The default token provider sends an authenticated,
non-cacheable same-origin `GET` request with `credentials: same-origin` and expects
a JSON object with one
`identity_token` string. The endpoint must issue a fresh JWT per request and
set `Cache-Control: no-store`; application-specific headers or CSRF behavior
may use a custom token-provider callback. The SDK places the initial token in
the iframe URL fragment. The iframe reads and removes that fragment before
starting its LiveView connection, retaining the token only in document memory.
It supplies the token through LiveView connect params; the parent never puts it
in a query string, cookie, history entry, prompt context or host command.
A cold-loading iframe can request a fresh token through the bootstrap listener
if its fragment token has aged out. Retry is bounded and does not reload the
page in a loop.

Integrated widgets authenticate during connected mount. Phoenix has already
verified the signed root LiveView page session before mount; the server binds
the JWT to that root `socket.id`. The unsigned initial render performs no
protected host work. Before host dispatch, subscription or history, the server
verifies signature, scope, times, and a cluster binding transaction. New JWT
binding requires `0 <= now - iat < 5` seconds, `iat` strictly later than
the cluster reset and user revocation cutoffs, and `now < exp`. An already
bound JWT may reconnect on the same verified page after the five-second window
until expiry, subject to revocation and runtime generation checks. It cannot
bind another page. An iframe reload creates a new verified page identity and
obtains a newly issued JWT. The browser cannot supply a binding ID. Each
connected mount creates a fresh process-owned Session; runtime replacement,
process ownership and expiry checks still apply. ZAQ separately authorizes the
selected conversation and every operation.

Binding records are keyed by issuer, audience, widget ID and JTI and retain
page ID, user ID, `iat` and `exp`. User cutoffs are keyed by issuer, widget ID
and user ID. A cluster reset cutoff records the earliest permitted issuance
after complete loss of RAM state. These are package-owned, replicated Mnesia
`ram_copies`, with majority-protected transactional reads/writes and bounded
expiry cleanup. Explicitly configured replica membership must establish a
quorum before initial creation or recovery; an isolated node must not create
an independent replacement store. A joining or restarting node loads surviving
state. Unavailable/minority authority fails closed. Complete RAM loss starts
a new cutoff only when a configured quorum can establish a new cluster. With
integer-second JWT times, a token issued in the cutoff second requires retry
with a token from a later second. No host Repo or SQL migration is needed.

A successful mount returns server-authoritative `expires_at`, `refresh_at`
and `server_time`. Renewal starts five minutes before expiry, configurable
with the lifetime constraint. The public parent API is
`zaq.widget.connect`; a temporary deprecated `init` alias may use the same
path. A new JWT is bound to the same verified page, widget and user, then
authorization expiry and generation-tagged timers change in place. Renewal
must preserve the subscription, submission correlation, independent assistant streams, selected conversation,
streaming deltas, messages, React component, draft and presentation settings.
The old binding remains usable by its page until its original expiry, so a
lost acknowledgement cannot strand a still-authorized session. Failed
renewal leaves the current session operational until actual expiry. At
expiry, protected sends and response application stop, and authorized history
recovery follows reconnection. The five-minute message-submission timeout
is independent from authentication renewal. A message with unknown outcome
is never automatically resent.

Recovery retires the old Chat's process/topic registrations, runtime monitor,
and expiry timer before opening its replacement on the host-authorized recipient topic.
Phoenix PubSub registrations are not reference-counted Chat handles: closing an
old Chat after subscribing its replacement would remove the replacement too.
Successful recovery reauthorizes the selected conversation and loads history
before enabling sends. Initialization/history failure cleans up the replacement
and leaves protected operations blocked. Proactive renewal continues to update
the existing Chat in place.

The bootstrap listener remains available outside the mounted LiveView hook,
including authentication failure, disconnect and forced revocation. It checks
the parent window and exact allowed origin. Internal bootstrap readiness means
the listener can receive presentation settings and authentication; public
`zaq.widget.ready` follows authentication and React/presentation setup.
A failed custom stylesheet may fall back to bundled styling. Normal network
reconnect uses the existing bound JWT without asking the provider for another.
The SDK deduplicates renewal triggers, retries transient provider failures with
bounded backoff, discards stale acknowledgements, suspends automatic issuer retries
while disconnected, and reschedules after
visibility or network restoration. It replaces its retained credential only
after server acceptance. A store reset requires a token issued after the
reset cutoff; temporary store unavailability retries availability without
repeatedly minting tokens. Revocation is terminal for that session: show
“Refresh the page to reconnect.” and suppress automatic token requests. SDK
lifecycle events include a reason, using the existing validated
`postMessage` result/event convention and exact source/origin checks.
A correctly signed and scoped credential covered by a user cutoff remains
`backend_revoked` after expiry. Signature, header, scope, claim shape and timestamp
consistency are validated before consulting that cutoff. Expired credentials are
never bound or authorized; an unavailable store reports `store_unavailable`, and
an expired credential without revocation remains recoverable. Terminal revocation
requires a parent-page refresh to create a new client, subject to backend approval.
The browser continues to use the existing LiveView WebSocket.

The iframe retains its latest selected conversation ID across connected mounts.
LiveView retains the requested ID even when mount authentication fails, separately
from a successfully authenticated Chat. It is untrusted context until the host
accepts it; recovery must not substitute a new conversation when restoration is
denied. Parent context replay follows newer server-confirmed selections.

The selected conversation ID accompanies message and history requests; ZAQ
authorizes resume and selection for the verified sender. Validated parent
prompt context accompanies the first question of a new conversation only and
remains ordinary input. A small parent context-update API may update that
input, but cannot change user identity, widget scope, routing authority or
authentication state. The package retains no credential in durable
conversation metadata. Standalone demo fixtures remain separate from the
integrated ZAQ runtime.

### Context-update failures

`widget.context.update` accepts `prompt_context: null`; callers need not supply
prompt context when selecting a conversation. Failed updates return
`%{ok: false, reason: safe_code, error: predefined_message}` without replacing the
current Chat. The same reply reaches parent `zaq.widget.result`, and the SDK uses
`error` as the rejected `updateContext()` promise's message.

| Safe reason | Meaning |
| --- | --- |
| `invalid_context_fields` | Unsupported fields or invalid conversation/prompt values |
| `submission_pending` | A local submission acknowledgement is still pending |
| `authentication_required`, `session_unauthorized` | Authentication is absent or the current Session is no longer authorized |
| `conversation_required` | A context update omitted the selection needed for an existing/blocked Chat |
| `conversation_unavailable` | The host denied the requested conversation; nonexistent, deleted, unbound and foreign conversations share this response |
| `host_unavailable`, `host_initialization_rejected` | Host initialization was unavailable or rejected |
| `invalid_host_response`, `unsupported_protocol_version` | Initialization response shape/correlation or protocol validation failed |
| `delivery_binding_missing`, `invalid_delivery_binding`, `delivery_binding_changed` | The private host delivery binding was missing, invalid or differed from the existing binding |
| `history_unavailable`, `invalid_history_response` | History dispatch was unavailable/rejected, or its response was malformed/uncorrelated |

Only closed error categories and fixed messages cross the browser boundary.
Validate semantic host-error protocol/correlation before classifying its allowlisted
code. Unknown host codes receive a generic stage-specific failure; raw host payloads,
exception details, topics, Person IDs and delivery descriptors are never echoed.
These errors do not settle submissions, change authentication policy or trigger retries.

A separate `web_widget_api("/widget-api")` router macro mounts package-owned,
stateless backend controls outside the browser route pipeline. Its disconnect
operation is `POST /widget-api/:widget_id/disconnect`. A backend proof is an
HS256 JWT in the `Authorization: Bearer` header, signed with that widget
connector's configured key. It has a strict claim set: `iss`, control-only
`aud`, `op: "disconnect"`, `widget_id`, `user_id`, integer `iat` and `exp`, and
random `jti`. The control audience is `identity_audience <> ":control"`,
distinct from the browser JWT audience;
validity is at most 30 seconds by default. The path widget ID and JSON body
user ID must match the signed claims. Runtime connector lookup supplies the key
and issuer for that scope. Other operations, unknown claims and ordinary browser
JWTs are rejected. The request nonce has a replicated idempotency result, so
retrying the same operation returns the same cutoff rather than advancing it.
Within one transaction, revocation commits the user cutoff before a scoped
broadcast. Matching sessions and subscriptions are invalidated, browsers
notified and widget transports closed. A user JWT issued in the cutoff's
integer second may need retry in the next second. Host backends must migrate
their JWT schema and provide the token endpoint before switching to the new
bootstrap API. Mnesia quorum, reset and recovery requirements are deployment
configuration, not browser responsibilities.

`allowed_domains` denies embedding when absent or empty, even on the same
origin. CSP `frame-ancestors`, exact parent source/origin checks and
HTTP(S)-only stylesheet URL validation remain required. Settings remain
separate from identity, and neither settings nor parent context can select a
host topic, connector or internal agent.

## Verified sender profiles

The backend identity JWT may additionally contain `profile`, a closed object with
`full_name`, `email`, and `phone`. It is covered by the existing HS256 signature,
widget/user/issuer/audience checks, binding, expiry and revocation policy. No
unsigned parent setting, init parameter, message or prompt context can override it.
Missing/null/empty profiles preserve user-ID-only authentication. Invalid profiles
reject the credential before binding; unknown fields reject rather than being copied.

Fields are optional strings or null. Strings must be valid UTF-8, nonblank,
already trimmed and free of ASCII control characters. `full_name` is at most 255
bytes; `email` is at most 254 bytes, with one `@`, a dotted domain and no whitespace;
`phone` is canonical international form (`+`, a nonzero leading digit, 7–15 digits
total). Values are preserved, not case-folded or matched by the widget. Signing
asserts the backend's profile provenance; it does not independently prove ownership
of an email address or phone number. Backends must source these fields from their
authenticated account records, not arbitrary request parameters.

The validated profile is retained only in the authenticated Session for request
transport. Before invoking the sink, the shared init, message and history preparation
path supplies the host Context constructor with the trusted option `:profile_context`:

```elixir
%{
  sender_id: verified_sender,
  channel_config_id: connector_id,
  profile: %{full_name: "Ada Example", email: "ada@example.com", phone: nil}
}
```

When the profile is absent, `profile_context` is nil. The envelope contains only
the three shown keys, and its profile has the three atom keys with nil for omitted
fields. Sender and positive integer connector ID come from the authorized Session,
never the event. Browser `profile`/`profile_context` fields are rejected as unknown
request fields. JWTs, signing keys, claims, page IDs and session handles are excluded.

Every dispatch retains the existing process ownership, expiry, binding/revocation
and runtime/infrastructure generation authorization checks. Successful renewal
replaces the Session's profile; omission/null/empty clears it. Failed or cross-sender
renewal leaves the current Session unchanged. There is no sender-global snapshot,
issuance watermark, same-second conflict rule, profile cache, lookup API or replicated
profile store. Independent still-authorized sessions carry their own signed assertions,
including reconnects using older unexpired credentials. Runtime replacement invalidates
old Sessions as before; reauthentication establishes a fresh Session.

This supersedes the earlier runtime-local `HostAdapter.fetch_profile/2` contract;
that API is removed. ZAQ's optional Web.Context.profile_context carries the envelope
through Engine and IdentityResolver unchanged to Channels.Api `:fetch_profile`.
WebBridge alone interprets it, validates the sender/connector binding, maps `full_name`
to `display_name`, and pins `channel_id` to the requested sender. Missing enrichment
allows the legacy user-ID-only path. The self-contained assertion can travel to any
Channels node without an ingress-node lookup. This is trusted in-process/distributed
host context, not a browser-supplied capability or a replacement for authentication.

ZAQ's existing IdentityResolver enrichment and `People.find_or_create_from_channel/2`
own email/phone matching. People is the only durable profile store. No profile fields
are added to Incoming, web Message, host commands, browser responses or conversation
metadata; the package introduces no compile-time ZAQ dependency. JWTs remain
browser-carried signed credentials, not encrypted containers.

## Inbound communication: web_widget -> ZAQ

Use the host constructor modules supplied in trusted hooks. Unknown wire events
and all inbound `message.edit` requests are rejected. Widget actions map as follows:

| Widget action | Shared operation |
| --- | --- |
| `widget.init` | Command `:conversation_init`, with request ID and optional validated resume ID |
| `conversation.history.request` | Command `:conversation_history`, with request ID, conversation ID and bounded history params |
| `message.create` | Message with request ID, message ID, UTC `DateTime`, content, channel, mode, optional conversation ID and first-question parent context |

The adapter chooses mode; the initial integration uses async questions. Channel
is a routing selector, not authority to select an internal agent. Do not send
capabilities, supplied history, actors, internal IDs or dispatch choices in messages.
Shared constructors validate the definitive fields and constraints.

ZAQ resolves the verified sender and connector into a Person. Only the host issues
the private Delivery descriptor for `consumer: :widget`, the trusted integer
configuration ID and its normalized `web_widget:recipient:<connector>:<person>`
topic, with all eight mappings:

```elixir
%{
  user_message: "response.user_message",
  typing: "response.typing",
  message_create: "response.message.create",
  message_edit: "response.message.edit",
  message_step: "response.message.step",
  message_complete: "response.message.complete",
  message_failed: "response.message.failed",
  error: "response.error"
}
```

New bindings include `user_message`. Existing explicitly trusted descriptors without
that mapping remain valid for enriched direct receipts only; the widget does not
subscribe to or invent an alternative user-message route. If present, the mapping
must be exactly `"response.user_message"`.

Build Context with nil actor, `consumer: :widget`, verified `sender_id`, integer
`channel_config_id` and the host-issued Delivery unchanged. Bootstrap initialization
uses nil Delivery; a subsequent initialization may carry the existing descriptor.
Nil actor grants no capability. Do not supply
BO bypasses, agent selection, history or content-filter overrides.

Invoke the published config-bound sink with its argument prefix:

```elixir
{module, function, args} = hooks.sink_mfa
apply(module, function, args ++ [payload, [context: verified_context]])
```

`sink_mfa` is an in-process callback, not a transport. Browser input cannot replace
it, its bound config, constructor modules or Context.

## Sync vs async events

| Operation | Sink result |
| --- | --- |
| Command | Semantic Response directly, including semantic `:error` on command failure |
| Async message accepted | `{:ok, Response}` creation/status receipt; no assistant answer is promised |
| Sync message | One status acknowledgement for a no-answer submission, or one terminal Response directly; no duplicate live terminal |
| Failure before acceptance | May return `{:error, reason}` |

Successful `:conversation_init` is the one private command-envelope exception:
`%{response: existing_public_response, delivery_binding: host_delivery}`. Unwrap it
only server-side, validate the response and subscription fields, and retain the
opaque host descriptor in Session. Its conversation/message IDs are nil and it
remains stable across selections. Neither the descriptor, its topic nor Person ID
may enter public Response.payload, LiveView props or parent postMessage. The widget
does not derive a destination from sender ID or interpret the topic's Person ID.
Missing/invalid bindings and initialization/subscription failures fail closed with
no page-topic, sender-topic, broad-topic or random-topic fallback.

Do not wrap all responses as `{:ok, map}` or reduce accepted receipts to `:ok`.
Distinguish valid semantic errors from success. Keep request and conversation
correlation through result handling and UI encoding. Assistant events additionally
carry their own stable transport message ID. ZAQ alone owns synchronous waiting;
the widget dispatch boundary preserves the direct result without publishing it again.

Acceptance acknowledges successful submission dispatch, not execution completion or
input consumption. It requires `protocol_version: 2`, the original `request_id`, an
authorized `conversation_id`, and `%{accepted: true, created: boolean,
user_message: canonical_public_row}` for the widget's async path. The saved row is
`%{message_id: canonical_id, position: positive_integer, role: "user", content:
saved_string, provider_sent_at: DateTime_or_nil}`, with optional existing public
history fields. ZAQ projects native external input roles to public `"user"` without
changing persistence. An async
fresh-chat receipt is `:conversation_created` with `created: true`; a resumed-chat
receipt is `:status` with `created: false`. Its `message_id` is absent or nil.
Neither receipt reserves an assistant ID. Submission `:error` also has absent/nil
`message_id` and settles only that submission. An unknown submission outcome blocks
resending until explicit authorized recovery, without failing existing assistants.
Legacy host sync behavior is unchanged.

After saving and successful routing, the host publishes a version-2 `:user_message`
Response on `"response.user_message"`, with the originating request ID, authorized
conversation ID, nil top-level message ID, and the exact same acceptance payload as
the direct receipt. The canonical nested user ID, never a locally fabricated ID,
identifies the displayed input. Direct receipts, live user events and history converge
through one idempotent canonical-user reducer. Position orders saved rows; a fast
assistant's persisted `user_message_id` or original request binding keeps it behind
its input when that canonical record arrives later. Conflicting IDs/positions and
user/assistant transport-ID collisions fail closed.

If the exact captured input cannot be recovered after routing, the host returns
`:acknowledgement_unavailable` with `outcome: :unknown` and any known conversation ID.
This is not a definitive rejection. The widget retains the draft, blocks duplicate
resubmission and retains that ID only as a restoration hint, requiring authorized
initialization/history before enabling an explicitly recovered Chat. A matching
saved-user broadcast may reconcile this tab's retained unknown request, including
establishing its first conversation when `created: true`. Another tab's event never
selects or switches conversations. A bounded process-local queue retains assistant
events for that unknown first request until the saved-user acknowledgement arrives;
no persistent stream snapshot store is introduced.

The composer retains its exact typed draft while sending, disables editing/send and
uses localized “Sending…” until acknowledgement. Only the originating tab's matching
acknowledgement clears the still-matching submitted draft. Other tabs receive the saved
user row but keep their independent draft and submission state. A tab-local
`submission_id` travels only over LiveView for late-ack correlation; it never replaces
the server-generated host request/message IDs or enters shared Context/Response.
Definitive rejection retains the draft and permits retry; timeout/disconnect or an
unknown outcome retains it and blocks resubmission until reconciliation. Neither
steering/no-answer receipts nor assistant-ui optimistic placeholders create a visible
pending assistant. Existing real assistant streams and known-active recovery indicators
remain independent from submission acknowledgement.

## Widget initialization

Opening a widget creates no chat or history. A fresh init returns
`:widget_initialized`, `created: false`, and no new conversation ID. Authorized
resume returns the existing ID; unknown, foreign, deleted or unbound IDs fail
without replacement creation.

The first-question sequence is:

```text
authenticate parent session -> host initialize -> bind private Delivery
  -> subscribe to host-authorized recipient destination
  -> authorized selected-conversation history/status (when resuming)
  -> enable sends (conversation_id nil for a fresh widget)
  -> submit first async question with retained optional prompt_context
  <- accepted conversation_created receipt with new conversation ID
  <- live typing / assistant events on the pre-existing subscription
```

Retain parent context until the first actual Message. ZAQ persists it as ordinary
user history when creating that conversation. Resume/later questions do not reseed.
An accepted resumed question returns `:status`, `accepted: true`, `created: false`.

Only a matching receipt or the matching saved-user recovery described above establishes
a new active conversation. Wait for its ID
before another submission. Clear the pending submission on the receipt, even if no
assistant event ever follows. Once accepted, later submissions can proceed while
earlier independent assistant messages continue streaming. Live events
may queue before the callback returns; process them only after acceptance is
bound. If dispatch moves to another process, explicitly buffer this race.

## Outbound communication: ZAQ -> web_widget

After authenticated host initialization, subscribe on the configured host PubSub
server using the returned private binding, before history or the first question.
Every tab/page initializes independently; the same connector/Person receives the
same destination, including after full reload. This replaces page-isolated delivery.
Page/JWT binding, expiry, renewal, revocation and runtime-generation authorization
remain independent security controls. A topic is not an authorization credential.

ZAQ publishes `{:web_response, adapter_event_name, shared_response}`. Consume that
single ingress and encode once into widget UI events; do not republish into the
old broad conversation topic. ZAQ keeps no LiveView PID. The widget knows only the
private recipient destination, local submission correlation and assistant transport IDs;
execution, root/child/receipt IDs, queued/steer/native runtime states and execution
management never enter widget state or UI events.

Check protocol version, trusted event mapping, the selected authorized conversation
and assistant transport message/request IDs before applying message events. Local
accepted-request membership is not required: authorized host-topic events may come
from an old page or another tab. Create, first full-body edit, or first terminal
establishes an assistant binding. Later events must retain that request and any
persisted references; steps alone never invent a row. Multiple independent streams
may share a request. Terminal states never regress, and duplicate/late events are
ignored per message. Unsolicited events cannot select or switch conversations.
Receipts/submission errors settle only their local submission; a matching canonical
saved-user event may reconcile that same local unknown request, never another tab's
send. User events bypass assistant stream correlation and never choose an assistant ID.
UI output retains the `response.*` namespace.

Subscribe before history so concurrent events queue in the LiveView mailbox.
Reconcile them after the authorized snapshot using persisted assistant/user refs,
including refs first learned after create. Existing canonical history rows suppress
duplicate live rows and stale snapshots. Do not replace a newer terminal or a live
independent stream with another history refresh. Missed-create full-body events
need no separate stream snapshot store. Missed terminals are recovered by authorized
history on reconnect; old-request terminals arriving later apply directly.
Canonical assistant history rows are finalized, never unfinished stream snapshots.
An active history response may therefore contain only the persisted user row while
the assistant's next full-body edit or terminal arrives through the subscription.

## Outbound payloads

### Public tool snapshots

ZAQ may attach optional `tool_steps` replacement snapshots to message edits,
steps, completions/failures, and canonical display-history messages. Each public
entry contains `id`, `kind: "tool"`, `name`, positive `sequence`, `state`
(`running`, `succeeded`, `failed`, or `unknown`), and optional nonnegative
`duration_ms`. The adapter validates and maps these into UI `tool_call` steps,
preserving identity, sequence and duration. No arguments, results or private
traces are accepted into UI state. The internal UI states map running to started,
succeeded to completed, and preserve failed and unknown.

Snapshots replace only the tool subset of a message's steps. Omission preserves
existing tools; an empty list clears them. Terminal snapshots override earlier
running tools without inferring success from answer completion. An uncompleted
tool without a terminal snapshot settles as unknown. Message terminals still
reject duplicate/late edits and steps. History restores the same public facts;
generic transient activity remains separate. The React activity panel displays
these existing tool cards, including recorded durations and an explicit unknown
outcome, over the existing LiveView connection.

Shared Response uses semantic `type`, `protocol_version: 2`, `request_id`, optional
`conversation_id`/`message_id` and public `payload`. Map this into the existing UI
vocabulary while preserving correlation; do not make ZAQ emit widget-private maps.

| Shared semantic type | Widget encoding / handling |
| --- | --- |
| `:widget_initialized` | `response.widget.initialized`; readiness with optional ID; displayed user comes from verified session |
| `:conversation_created` | `response.conversation.created`; direct correlated receipt establishes the conversation |
| `:conversation_history` | `response.conversation.history`; ordered public messages and separately retained pagination positions |
| `:status` with accepted true | Direct resumed receipt (or sync no-answer acknowledgement), not assistant text or an assistant terminal |
| `:user_message` | Canonical saved input; deduplicated with its direct receipt/history, with no assistant transport message ID |
| `:typing` | `response.typing`, boolean `active` |
| `:message_create`, `:message_edit`, `:message_complete` | Corresponding `response.message.*`; top-level transport `message_id` becomes UI payload `id`, public `body` becomes `content` |
| `:message_step` | `response.message.step`; public `step_id` and message ID, safe label; `:activity/:running` maps to `status/started` or `updated` for an existing step |
| `:message_failed` | `response.message.failed`; correlated message ID and public `body` as UI error text, with a generic fallback when `body` is absent or blank; do not expose raw error details |
| `:error` | Submission error; correlated request and safe code/text, nil/absent message ID; retain timeout `outcome: :unknown`, never fail unrelated assistant messages |

Public failure bodies use the same safe Markdown/link rendering as assistant text;
raw HTML and executable URL schemes are not enabled. The host owns public wording
and recovery URLs. Rendered content links open in a new tab with `target="_blank"`
and `rel="noopener noreferrer"`, never replacing the widget iframe or parent page.
This applies equally to ordinary assistant responses and public failure bodies.
An accepted execution that fails before streaming still sends
`:message_create` before `:message_failed` with the same transport message ID;
it is not a submission rejection. An optional inactive typing hint may precede the
terminal failure. True submission rejection remains `:error` without an assistant.

ZAQ streaming edits are cumulative snapshots. LiveView keeps the full content,
but sends only the new suffix to React when an edit extends a running message
without changing its other fields. Full replacements still use the message stream.
Status and reasoning steps use only transient progress presentation, not persistent
activity cards. Only explicit `tool_call` and `tool_result` steps appear in the
activity panel and its counts; generic activity labels never imply tool execution.
The assistant transport ID is stable across create/edit/step/terminal and may differ
from persisted assistant/user message references. Retain those references separately.
Never expose BO traces, private reasoning, raw tool calls or agent metadata.

The host normally emits create before edits/steps and one terminal per stream;
the widget can recover from a missed create using a full-body edit or terminal.
Interleaving across streams is allowed. Update steps by step ID; terminal message/step
states cannot regress. Ignore duplicate creates, duplicate/late terminals and late
edits/steps per message, not per chat. `:typing` is optional public presentation only;
it neither acknowledges submission nor promises an assistant. Aggregate correlated
typing hints without letting another request's inactive hint clear current progress.
Typing after a request's known streams have all terminated is ignored. No-answer
acceptance needs no typing or terminal. A later independent create can still carry
the original host request ID, without a local submission.

## Conversation ownership and history

ZAQ owns durable history; LiveView owns current browser state. Do not send complete
history with each question. Resume must verify identity, authorize the selected ID
and load history before accepting another send. Full page reload restoration requires
an explicit parent resume mechanism retaining the accepted ID; browser identity alone
or prior LiveView memory does not guarantee restoration.

LiveView delivers message rows to React through a LiveReact stream. Ordinary
updates insert or replace only changed messages; typing-only updates carry no
message rows. History restoration and conversation changes may reset the stream.
Locale changes refresh localized row summaries. The server retains canonical
conversation state; the stream only changes browser delivery.

Shared history params are `limit` (default 50, maximum 100), `after_position` and
`up_to_position`. Preserve returned positions for bounded pagination, distinct from
conversation/transcript identifiers. Render oldest to newest, normalizing public IDs,
roles and timestamps. Never invent timestamps for untimestamped history. Preserve
message creation times during streaming; format dates in the selected language and
browser time zone.

The same public history response adds `payload.processing: :active | :idle | :unknown`.
The host performs its authorized native-runtime lookup; no native IDs, PIDs or
execution records enter the widget. `:active` shows the existing processing indicator
without inventing an assistant, pending submission or per-send spinner.
Before an actual running assistant row is available, the conversation also shows
the existing localized “Preparing your answer” working indicator as presentation
only. It disappears when a real running row takes over, without adding a message
ID or changing submission state. Terminal
events or inactive typing clear recovered progress; independent active typing hints
remain aggregated. `:unknown` is uncertainty, not completion or cancellation, and
does not manufacture a terminal. No-answer/steering receipts retain their ordinary
submission-only semantics. No additional command or browser connection is introduced.

PubSub offers no durable replay or exactly-once execution. A display timeout concerns
only an outstanding transport submission receipt, never a promised assistant or an
accepted execution. Timeout is an unknown outcome, not cancellation or permission
to retry. Accepted assistant streams can finish later and are not timed out by the widget.
Recover through authorized history when the conversation ID is known. If an initial
timeout returns no ID, surface unresolved outcome rather than inventing an ID or
silently resending. Consult the host contract for timeout bounds.

Multiple-conversation listing/sidebar integration is deferred. The existing mock's
`include_conversations` response is not part of the shared ZAQ history command.

## Parent-owned presentation settings


Theme and language are not persisted ZAQ widget configuration. Each iframe starts
with `%{theme: "light", language: "en"}`. Its allowed parent sends
`zaq.widget.settings.update` separately from init, or optionally inspects current
values with `zaq.widget.settings.get`. Settings in init are rejected.
Supported values: theme `auto/light/dark`, language `en/fr/ar`. Unknown keys and
invalid values reject the entire update. Settings cannot change identity, routing,
origins, stylesheet URLs, or conversation ownership. Init never changes settings;
repeated init does not rewind runtime preferences.

Requests may carry `request_id`; the iframe replies to the validated parent origin
with `zaq.widget.result`, the same ID, and either `ok: true, settings: {...}` after
application or `ok: false, error: "..."`. Both sides verify source and exact origin.
The parent client uses these messages and a timeout; it owns no conversation state.
Settings survive LiveView reconnects in the same iframe document. Reloading the
iframe resets its defaults; the parent client reapplies its latest preferences.

Gettext supplies UI strings and plural summaries, and the browser formats dates
in the selected language and local time zone. Arabic switches the document to RTL.
Host content remains unchanged. Runtime updates preserve drafts, messages, pending
responses, and selected conversations. Custom CSS may override color tokens but
there is no theme-selection CSS variable. ZAQ owns its response language.

The parent may load `/web_widget/assets/embed.js` to expose `zaq.widget` for a
single iframe (`#zaq-widget`, or `#zaq-widget-frame` when its container owns that ID).
This wrapper owns outer iframe defaults, validated resize handling and parent
scroll locking. The authenticated script obtains a backend-issued JWT, while
`zaq.widget.connect` handles replacement credentials in place. The lower-level
client remains available for independent widget instances. The internal
bootstrap-ready handshake supports clients attaching after iframe load without
navigating it again; public readiness follows authentication and presentation.
Source and origin checks apply to both stages. The embed script supplies optional
custom CSS; bundled defaults remain available. Duplicate stylesheet decisions
retain the active loading promise and link. Replacement or removal settles obsolete
waiters; readiness follows the current load, error, or three-second fallback.
Events from a removed link cannot settle its replacement. Authentication proceeds
independently, and background renewal does not create another public-ready transition.

## Implemented delivery boundary

This section records migration evidence, **not another supported ZAQ contract**.
At package revision `a134225f3f059768be6742cc92acfd1192e1fce7`:

- `Runtime.dispatch/1` calls `apply(module, function, [event | args])` and its mock
  returns `{:ok, response_map}` for init/history or `:ok` for accepted messages.
- `Events` and `Response.normalize/1` require a nonblank conversation ID before
  message delivery; initialization supplies that ID eagerly.
- `Adapter.send_event/1` publishes `{:web_widget_response, event}` on an encoded
  widget/conversation topic; WidgetLive subscribes after initialization.
- Bootstrap checks ID shape, origin and source, but does not verify identity proof.
  Mounted views are not automatically revoked by runtime changes.
- Mock history is fixture data; multi-conversation UI and callbacks do not prove
  canonical persistence, authorization or the shared ZAQ lifecycle.

Milestone 1 adds `Integration.RuntimeBuilder`, `Integration.Protocol` and
`Integration.Session` while preserving public configuration lookup. The old
`Runtime.dispatch/1` rejects integrated runtimes with `:authentication_required`;
authenticated callers use `Runtime.dispatch(event, session)`. The new internal
event maps carry the operation/request fields only, not `widget_id` or `user_id`:
the session supplies trusted identity/scope. Unknown fields/events and message
editing are rejected. Raw resume IDs are checked before shared construction.
Responses retain the host's return shapes; UI encoding is milestone 2.

Milestone 2 adds `Integration.Chat` and semantic `Integration.Response` encoding.
Integrated runtimes use only the verified shared path in WidgetLive. A shared host
fixture and browser smoke exercise that path, including responses queued before
acceptance. Legacy standalone demo callbacks remain supported for existing
consumers, but cannot dispatch to integrated runtimes. See
[authenticated chat](authenticated-chat.md) for the current configuration and
single-node replay behavior, which issue #14 replaces.
