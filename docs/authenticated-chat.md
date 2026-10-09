# Authenticated ZAQ chat smoke and operations

## Host setup

Mount `web_widget("/widget")` in the host browser pipeline and `web_widget_api("/widget-api")` in a separate backend API scope. Serve the installed assets before the router and expose the existing LiveView socket at `/live`. Configure connector-key verification, issuer, audience, host PubSub, and explicit Mnesia replica membership. See [host integration](host-integration.md) for the complete mount.

```elixir
config :web_widget, :integration,
  pubsub_server: Zaq.PubSub,
  identity_verifier: :connector_key

config :web_widget, :authentication,
  token_ttl_seconds: 604_800,
  first_binding_window_seconds: 5,
  refresh_lead_seconds: 300,
  control_proof_ttl_seconds: 30,
  replica_nodes: [:"node1@host", :"node2@host", :"node3@host"]
```

Use your real node names and keep the same membership on every node. The package stores JWT page bindings, user revocation cutoffs, control request results, and reset metadata in replicated Mnesia `ram_copies` with majority reads/writes. It requires a configured quorum to create or recover the tables. A minority fails closed. A node that restarts rejoins surviving RAM state; complete RAM loss establishes a reset cutoff at quorum. Tokens issued at or before that cutoff cannot bind; with integer-second timestamps, issue a new token in a later second. No host SQL migration is needed. The token lifetime must exceed the renewal lead.

The resolved connector `config.token` is read privately by the runtime builder. Store its copy only on the embedding website's backend. Keep Phoenix filtering for `token` and `secret` enabled. Install the package's JOSE dependency through normal host dependency setup. Do not put the connector key in HTML, browser JavaScript, the token endpoint response, or the installation script.

## Identity and parent context

Connector settings must contain `"identity_issuer"` and `"identity_audience"`.
ZAQ's new-connector defaults are `zaq_issuer` and `zaq_audience`; the example below
uses those values. Use the actual configured identifiers when signing. Missing or
invalid settings reject construction, with no legacy fallback; upgrade atomically.
Rebuild the connector runtime after edits to apply them and revoke old sessions.

The parent backend signs a compact HS256 JWT with protected header exactly `{"alg":"HS256","typ":"JWT"}`. Required claims are numeric positive `widget_id`, authenticated `user_id`, matching `iss` and `aud`, integer `iat` and `exp`, and random `jti` (16–255 characters). Optional integer `nbf` is enforced. The raw UTF-8 connector key is the HMAC secret; do not Base64-decode it. Unknown claims and old Phoenix.Token proofs fail closed. The default maximum JWT lifetime is seven days.

```elixir
{:ok, identity_token} = WebWidget.Integration.SignedIdentity.sign(
  connector_key, 12, %{user_id: authenticated_external_user_id},
   issuer: "zaq_issuer", audience: "zaq_audience"
)
```

Expose a same-origin authenticated `GET /api/widget-token` on the embedding website. Return `{"identity_token":"<JWT>"}` and `Cache-Control: no-store`. The installation script can fetch it through `data-token-url="/api/widget-token"`. It puts the first token in the iframe URL fragment; the iframe removes the fragment before LiveView connects. The public parent API is `zaq.widget.connect()`. `zaq.widget.init({identity_token})` remains a deprecated direct-token alias; unsigned `user_id` works only in standalone mock fixtures.

Conversation ID and prompt context are **not JWT claims**. Once `zaq:ready` fires, the parent may call `zaq.widget.updateContext({conversation_id})` to ask ZAQ to authorize and load an existing conversation, or `zaq.widget.updateContext({prompt_context})` to retain validated plain text for the first new question. Foreign, deleted, and unknown IDs fail without creating a replacement. Parent context cannot change identity, widget scope, routing, or authentication. Clear saved IDs on logout or account change. The first accepted question creates a conversation and emits `zaq:conversation` with its ID; opening the widget alone creates none.

The host receives the selected conversation ID on message and history requests and authorizes the verified sender. A resumed or later question does not reseed prompt context. A request whose result is unknown remains blocked until explicit authorized history recovery; it is never resent automatically.

## Renewal and disconnect

The server returns `expires_at`, `refresh_at`, and `server_time`. The parent client schedules a new token five minutes before expiry by default, deduplicates requests, retries transient failures, and refreshes the bound session in place. Its subscription, selected conversation, active response, draft, and settings remain. A normal LiveView reconnect reuses the same bound JWT. A full iframe page load needs a new token because first binding is limited to five seconds and one page. At expiry, sending and response application pause until fresh authorization succeeds. A five-minute message submission timeout is a separate limit.

The selected conversation survives an authentication failure during reconnect,
including expiry, store unavailability, and RAM reset. Once authenticated, the
host must authorize that same ID and restore its history before sending resumes.
Denied restoration stays blocked and never creates a replacement conversation.
Recovery replaces subscriptions on the same page topic only after retiring the
previous Chat; it never resends the original question. A late terminal response
can trigger authorized history recovery for the restored conversation.

The backend control endpoint is `POST /widget-api/:widget_id/disconnect`. The parent backend signs a distinct HS256 JWT in the `Authorization: Bearer` header. Its strict claims are `iss`, `aud: identity_audience <> ":control"`, `op: "disconnect"`, numeric `widget_id`, `user_id`, integer `iat` and `exp`, and random `jti`; maximum lifetime is 30 seconds. The JSON body contains exactly `{"user_id":"..."}`. The path and body must match the proof. A browser identity JWT cannot authorize this endpoint.

```elixir
{:ok, proof} = WebWidget.Integration.ControlProof.sign(
  connector_key, 12, authenticated_external_user_id,
  issuer: "test-widget", audience: "zaq-web-widget:control"
)
# POST /widget-api/12/disconnect with Authorization: Bearer <proof>
# and JSON {"user_id":"<authenticated_external_user_id>"}
```

The cutoff is committed transactionally before a scoped PubSub broadcast. Retrying with the **same proof** returns the same cutoff; use a new proof for a new operation. Matching sessions and subscriptions are invalidated. The iframe displays “Refresh the page to reconnect.”, emits `zaq:authentication-required` with `reason: "backend_revoked"`, and closes its LiveView transport. The parent stops token renewal for that iframe. A signed, scoped credential remains terminally revoked even if it expired while
offline. Expiry never permits authorization or a new binding. Store unavailability
is reported separately and retried once authority returns. Refresh the parent
page to create a new client; its backend must still authorize fresh issuance.
A new token issued in the cutoff second may need to be issued again in the next second.

## Smoke checks

Check a fresh mount, first question, live response, saved conversation resume, renewal during streaming, expiry recovery, and backend disconnect. Confirm other users and widget IDs remain active after a targeted disconnect. Browser coverage lives in `assets/tests/auth-bootstrap.spec.ts` and `assets/tests/shared-widget.spec.ts`; the integration tests exercise scope, proof rejection, replay, and cutoff races. The constructor smoke loads the sibling ZAQ contract without a live agent/model.

For response diagnostics, set `Application.put_env(:web_widget, :response_diagnostics, :summary)` in ZAQ's IEx session. Logs show field presence and outcome without payload values. `true` logs complete responses and may include private content; use it only briefly while debugging, then restore `false`. ZAQ currently reduces tool status to generic activity steps; the widget cannot infer real tool calls without an agreed public tool event contract.
