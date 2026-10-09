# Web Widget Adapter Contract

## Status and source of truth

Decision recorded in wiring milestone 0, 2026-10-05. This document defines the
selected ZAQ integration against shared web protocol **version 1** at
[`c38e7e4e5`](https://github.com/www-zaq-ai/zaq/blob/c38e7e4e5/docs/services/web-bridge.md).
ZAQ's [installation handoff](https://github.com/www-zaq-ai/zaq/blob/c38e7e4e5/docs/guides/web-widget-integration.md)
and published constructors own the host protocol. This document owns the widget's
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

Use the existing channel lifecycle and BridgeSupervisor. The provider entry in
ZAQ's existing Channels map is:

```elixir
web_widget: %{
  bridge: Zaq.Channels.WebBridge,
  adapter: WebWidget.Integration.RuntimeBuilder
}
```

`WebWidget.Integration.RuntimeBuilder.build(config, hooks)` returns
`{:ok, {state_child_spec_or_nil, listener_specs}}` or `{:error, reason}`.
It reuses the package runtime registry. ZAQ owns startup, rollback, restart and
teardown lifecycle; do not independently start a duplicate runtime. The local
ZAQ installation now selects this builder through configuration and a path
dependency; no ZAQ module or test changes are needed for runtime startup.

Hooks supply `widget_id = config.id`, presentation settings, the shared
`message`, `command`, `context`, `delivery`, `response` modules, and the
config-bound `sink_mfa`. They do **not** supply a PubSub server. For this host,
the adapter receives `Zaq.PubSub` through trusted application configuration.
`config :web_widget, :integration` supplies `pubsub_server` and `identity_verifier`
(a trusted MFA or `:connector_key`); `build/3` accepts these options explicitly for
isolated consumers/tests. Neither connector settings nor browser input may select
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
runtime rebuild; old sessions lose runtime-generation authorization and proofs
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
ZAQ v1 does not provide the current widget's eager conversation-list contract.

The local ZAQ install mounts the package router on its existing endpoint.
Released Git tags contain the built bundle in `web_widget/priv/static/assets`.
The `web_widget/1` router macro serves those files at `/web_widget/assets/*path`
from the dependency itself. ZAQ does not copy or build assets, change its static
path allowlist, or add `WebWidget.Static` to its endpoint. Its scoped
`/widget/:widget_id/live` socket serves the iframe; BO authentication does not apply to the widget mount.
This supersedes the earlier configuration-only choice for this installation.

For hosts retaining configuration-only installation, opt in to
`start_integration_server: true` to start the package endpoint and its socket
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
SameSite policy, and require Secure/HTTPS. Only trusted host endpoint configuration
may disable partitioning (`web_widget_session: [partitioned: false]`), for example
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
initial document bootstrap may initialize a cookie. Subsequent token resynchronization
is read-only and has a document-lifetime attempt limit. Initial LiveView establishment
and each transient reconnect have finite deadlines; opening a transport alone does
not reset them. Failure stops recovery and offers explicit reload, never automatic
reload or cookie-writing recovery. Cookie policy changes require a fresh page load.

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
using the trusted `:widget_path` mount prefix (default `/widget`) and public origin.
The iframe renders its scoped transport URL; no JWT enters either URL's query.
Host router, endpoint socket mount, proxy and installation prefix must agree.

## Adapter readiness (version 1)

The configured adapter optionally exposes `status(widget_id, timeout_ms: 2_000)`.
The ID is a positive integer and the timeout is a total budget, capped at 2 seconds.
ZAQ independently bounds invocation and validates the closed response. Old adapters
without this callback remain supported; missing support never means ready.

The response is `{:ok, %{protocol_version: 1, status: state, reason: reason,
checks: checks, effective_settings: settings}}`. All five checks are required, in
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
are connector-owned; legacy SameSite inherits the serving endpoint's policy.
Sources allowed by the protocol are connector/application/default, plus endpoint
for SameSite. Unresolved is `%{value: nil, source: :unresolved}` and cannot be
ready. Custom verifiers without provable effective identity settings are not green.
ZAQ owns comparison against current desired settings, disabled state, NodeRouter
invocation and refresh of both BO surfaces after lifecycle changes.

Readiness checks the configured serving host endpoint in mounted mode or the
package endpoint in package mode. It obtains an anonymous page cookie and CSRF
token, verifies widget-only attributes, and upgrades the widget-scoped WebSocket.
It does not join a LiveView channel, authenticate a user, consume a JWT, create a
conversation, require visitors, or start a listener. These ephemeral probe values
never appear in results. A healthy BO `/live` or long-poll transport is insufficient.
Listener observations are endpoint-wide; session/handshake results are widget-specific
and are not retained across calls, avoiding stale green after lifecycle changes.

This proves local listener/session/transport readiness only. It does not prove
public proxy routing, TLS termination, real-user authentication or browser cookie
acceptance. None requires an actually verified HTTPS session path; an unverifiable
TLS-terminating topology must stay unknown rather than trust a public URL string.
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

Package authentication configuration uses `config :web_widget, :authentication`
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
must preserve the subscription, active request, selected conversation,
streaming deltas, messages, React component, draft and presentation settings.
The old binding remains usable by its page until its original expiry, so a
lost acknowledgement cannot strand a still-authorized session. Failed
renewal leaves the current session operational until actual expiry. At
expiry, protected sends and response application stop, and authorized history
recovery follows reconnection. The five-minute message-submission timeout
is independent from authentication renewal. A message with unknown outcome
is never automatically resent.

Recovery retires the old Chat's process/topic registrations, runtime monitor,
and expiry timer before opening its replacement on the same page-stable topics.
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

Build Delivery for `consumer: :widget`, trusted integer configuration ID and an
authorized session topic, with all seven mappings:

```elixir
%{
  typing: "response.typing",
  message_create: "response.message.create",
  message_edit: "response.message.edit",
  message_step: "response.message.step",
  message_complete: "response.message.complete",
  message_failed: "response.message.failed",
  error: "response.error"
}
```

Build Context with nil actor, `consumer: :widget`, verified `sender_id`, integer
`channel_config_id` and Delivery. Nil actor grants no capability. Do not supply
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
| Async message accepted | `{:ok, Response}` creation/status receipt; terminal comes later |
| Sync message | One terminal Response directly; no duplicate live terminal |
| Failure before acceptance | May return `{:error, reason}` |

Do not wrap all responses as `{:ok, map}` or reduce accepted receipts to `:ok`.
Distinguish valid semantic errors from success. Keep request, conversation and
message correlation through result handling and UI encoding.

## Widget initialization

Opening a widget creates no chat or history. A fresh init returns
`:widget_initialized`, `created: false`, and no new conversation ID. Authorized
resume returns the existing ID; unknown, foreign, deleted or unbound IDs fail
without replacement creation.

The first-question sequence is:

```text
verify parent session -> readiness (conversation_id nil)
  -> subscribe to authorized session destination
  -> submit first async question with retained optional prompt_context
  <- accepted conversation_created receipt with new conversation ID
  <- live typing / assistant events on the pre-existing subscription
```

Retain parent context until the first actual Message. ZAQ persists it as ordinary
user history when creating that conversation. Resume/later questions do not reseed.
An accepted resumed question returns `:status`, `accepted: true`, `created: false`.

Only a matching receipt establishes a new active conversation. Wait for its ID
before another submission and preserve the active-response guard. Live events
may queue before the callback returns; process them only after acceptance is
bound. If dispatch moves to another process, explicitly buffer this race.

## Outbound communication: ZAQ -> web_widget

Subscribe on the configured host PubSub server before the first question using
a server-derived destination scoped to the verified root `socket.id`. It must
exist without a conversation ID. Renewal and ordinary reconnect reuse that
page's destination after verification; an iframe reload receives a new root
socket ID and destination. The topic is not an authorization credential: verify
the session and correlate every response before applying it. Integrations
without a verified page ID retain a fresh random destination per session.

ZAQ publishes `{:web_response, adapter_event_name, shared_response}`. Consume that
single ingress and encode once into widget UI events; do not republish into the
old broad conversation topic. ZAQ keeps no LiveView PID. Its RequestOwner's internal
reply topic is separate from the adapter session destination.

Check protocol version, trusted event mapping, request ID, accepted conversation
and transport message ID before applying events. Widget ID and sender come from
the session. Reject stale/foreign responses; unsolicited events cannot switch
conversations. UI output retains the `response.*` namespace.
After a connected remount, the accepted request IDs from the former LiveView are
gone. A valid terminal event for the already authorized conversation may trigger
a fresh authorized history request; its payload is never applied as a stream
event without the original request correlation.

## Outbound payloads

Shared Response uses semantic `type`, `protocol_version: 1`, `request_id`, optional
`conversation_id`/`message_id` and public `payload`. Map this into the existing UI
vocabulary while preserving correlation; do not make ZAQ emit widget-private maps.

| Shared semantic type | Widget encoding / handling |
| --- | --- |
| `:widget_initialized` | `response.widget.initialized`; readiness with optional ID; displayed user comes from verified session |
| `:conversation_created` | `response.conversation.created`; direct correlated receipt establishes the conversation |
| `:conversation_history` | `response.conversation.history`; ordered public messages and separately retained pagination positions |
| `:status` with accepted true | Direct resumed receipt, not assistant text or a terminal |
| `:typing` | `response.typing`, boolean `active` |
| `:message_create`, `:message_edit`, `:message_complete` | Corresponding `response.message.*`; top-level transport `message_id` becomes UI payload `id`, public `body` becomes `content` |
| `:message_step` | `response.message.step`; public `step_id` and message ID, safe label; `:activity/:running` maps to `status/started` or `updated` for an existing step |
| `:message_failed` | `response.message.failed`; correlated message ID and public `body` as UI error text, with a generic fallback when `body` is absent or blank; do not expose raw error details |
| `:error` | `response.error`; correlated request and safe code/text; retain timeout `outcome: :unknown` |

ZAQ streaming edits are cumulative snapshots. LiveView keeps the full content,
but sends only the new suffix to React when an edit extends a running message
without changing its other fields. Full replacements still use the message stream.
Status and reasoning steps use only transient progress presentation, not persistent
activity cards. Only explicit `tool_call` and `tool_result` steps appear in the
activity panel and its counts; generic activity labels never imply tool execution.
The assistant transport ID is stable across create/edit/step/terminal and may differ
from persisted assistant/user message references. Retain those references separately.
Never expose BO traces, private reasoning, raw tool calls or agent metadata.

Live ordering is typing active -> assistant create -> optional edits/steps -> typing
inactive -> one correlated terminal. A create precedes subsequent assistant events.
Update steps by step ID; terminal message/step states cannot regress. Ignore duplicate
or late terminals and typing resets from earlier requests.

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

PubSub offers no durable replay or exactly-once execution. Timeout is an unknown
outcome, not cancellation or permission to retry. Accepted work can finish later.
Recover through authorized history when the conversation ID is known. If an initial
timeout returns no ID, surface unresolved outcome rather than inventing an ID or
silently resending. Consult the host contract for timeout bounds.

Multiple-conversation listing/sidebar integration is deferred. The existing mock's
`include_conversations` response is not part of the shared ZAQ v1 history command.

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
