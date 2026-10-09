# Integrate the ZAQ Web Widget on your website

Your backend authenticates the visitor and issues a signed identity JWT. The installation script fetches that JWT from your same-origin endpoint, mounts the iframe, and renews authorization. ZAQ owns conversation authorization and durable history. The widget uses its existing LiveView WebSocket.

## Configure ZAQ

Create and enable a Web Widget connector in **Channels → Communication → Web Widget**. Add each exact website origin to **Allowed embedding origins**. An empty list denies embedding. Save the generated authentication key in your website backend's secret store. Its public numeric connector ID appears in the installation script.

ZAQ must serve `/web_widget/assets`, `/widget/:id`, `/widget-api/:id/disconnect`, and `/live` from its public HTTPS origin. The host mounts `web_widget("/widget")` in a browser pipeline and `web_widget_api("/widget-api")` in a separate backend API scope. The latter has no browser session or CSRF dependency; its signed proof is mandatory.

Connector-key verification uses trusted host options:

```elixir
config :web_widget, :integration,
  pubsub_server: Zaq.PubSub,
  identity_verifier: :connector_key
```

Set **Identity issuer** and **Identity audience** on the connector. Canonical
settings keys are `identity_issuer` and `identity_audience`; new-connector defaults
are `zaq_issuer` and `zaq_audience`. Values must be exact UTF-8 strings of 1–255
bytes without surrounding whitespace. Both are mandatory, with no adapter default
or application-option fallback. Upgrade existing connectors atomically. Edits
require a runtime rebuild and invalidate old sessions and old-claim tokens.

The backend control audience is `identity_audience <> ":control"`, here `zaq_audience:control`. Keep the key on the backend. Use its exact UTF-8 bytes for HS256; do not Base64-decode it.

## Issue identity tokens

The protected header is exactly `{"alg":"HS256","typ":"JWT"}`. Required claims are a positive integer `widget_id`, nonblank `user_id`, matching `iss` and `aud`, integer Unix-second `iat` and `exp`, and a fresh random `jti` of 16–255 characters. Optional integer `nbf` is enforced. Unknown claims, including `conversation_id`, `prompt_context`, and settings, are rejected. The default maximum lifetime is **seven days**; configure `token_ttl_seconds` on ZAQ if needed. `exp` must follow `iat`, and backend and ZAQ clocks must agree.

The backend derives `user_id` from its authenticated session. A JWT is readable by the browser, so do not include private application data. For a Node backend, install `jose` with `npm install jose`:

```js
import { SignJWT } from "jose";
import { randomUUID } from "node:crypto";

const key = new TextEncoder().encode(process.env.ZAQ_WIDGET_SECRET);

async function issueWidgetToken(authenticatedUserId) {
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({ widget_id: 12, user_id: String(authenticatedUserId) })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setIssuer("zaq_issuer")
    .setAudience("zaq_audience")
    .setIssuedAt(now)
    .setExpirationTime(now + 604800)
    .setJti(randomUUID())
    .sign(key);
}
```

Create a **same-origin** authenticated `GET /api/widget-token` endpoint on your website. It should return `{"identity_token":"<JWT>"}` with `Cache-Control: no-store`. Use the website's normal session protection. Do not accept a user ID or connector key from the browser. Give an anonymous visitor a stable backend session if anonymous chat is intended.

## Install and use the widget

Add the script once per page. If the generated script omits `data-token-url`, add it or ask the ZAQ host to configure `token_url` for the generated snippet. It is a same-origin URL on **your website**, not ZAQ:

```html
<script src="https://YOUR-ZAQ-HOST/web_widget/assets/embed.js"
        data-widget-id="12" data-token-url="/api/widget-token" defer></script>
```

The script fetches a token before creating `#zaq-widget`, places it in the iframe URL fragment for the initial LiveView connection, and removes it from iframe history after reading. It validates the endpoint's `no-store` response. The connector key never reaches the browser. The parent client schedules renewal from the server's `expires_at`, `refresh_at`, and `server_time`, deduplicates concurrent requests, retries transient failures, and renews in place without clearing drafts or streaming responses.

For custom token transport, load `embed.js` without `data-widget-id`, call `zaq.widget.setTokenProvider(async signal => token)`, then `zaq.widget.mountAuthenticated(widgetUrl, optionalDivSelector, optionalStylesheetUrl)`. `zaq.widget.connect()` manually requests a fresh token from the provider. `zaq.widget.init({identity_token})` is a deprecated migration alias for direct token delivery; integrated widgets reject unsigned `user_id` initialization.

Opening the widget creates no conversation. To resume, retain the ID emitted in `zaq:conversation`, then call `updateContext` after public readiness. ZAQ checks that the verified user may resume it; unknown or foreign IDs fail without creating a replacement. Plain prompt context is sent only with the first question of a new conversation and is not identity or routing authority.

```js
// Run in a module script after the installation script has loaded.
const frame = await new Promise(resolve => {
  const existing = document.getElementById("zaq-widget");
  if (existing) return resolve(existing);
  const observer = new MutationObserver(() => {
    const mounted = document.getElementById("zaq-widget");
    if (mounted) { observer.disconnect(); resolve(mounted); }
  });
  observer.observe(document.body, { childList: true });
});
const key = "zaq-conversation-12";
frame.addEventListener("zaq:conversation", event => {
  sessionStorage.setItem(key, event.detail.conversation_id);
});
async function restore() {
  const conversation_id = sessionStorage.getItem(key);
  if (conversation_id) await zaq.widget.updateContext({ conversation_id });
  else await zaq.widget.updateContext({ prompt_context: `Current page: ${location.pathname}` });
}
frame.addEventListener("zaq:ready", () => { void restore().catch(console.error); });
if (zaq.widget.isReady()) void restore().catch(console.error);
```

Clear the stored ID on logout or account change. Changing the verified user requires a new iframe page. A full iframe reload requires a fresh token; a token bound to another page cannot be reused. A normal LiveView reconnect keeps its existing token and subscription. On expiry, sending pauses and the parent requests a new token. A five-minute message timeout is independent of token renewal; unknown-outcome messages are never resent automatically.

The iframe emits `zaq:ready`, `zaq:authenticated`, `zaq:authentication-required`, `zaq:disconnected`, and `zaq:conversation` on the iframe element. Inspect `event.detail.reason` for failures such as `expired`, `store_unavailable`, or `backend_revoked`. Backend revocation is terminal for that iframe: the widget displays “Refresh the page to reconnect.” and closes its LiveView transport. The parent client stops requesting tokens until a page refresh.

Presentation is separate from identity:

```js
await zaq.widget.updateSettings({ theme: "dark", language: "ar" });
const settings = await zaq.widget.getSettings();
```

Theme accepts `light`, `dark`, or `auto`; language accepts `en`, `fr`, or `ar`. Accepted settings are reapplied after an iframe reload by the parent client. Persist website preferences yourself across full website page loads.

## Backend disconnect

On logout or an administrative revocation, the website backend can call `POST https://YOUR-ZAQ-HOST/widget-api/12/disconnect` with JSON `{"user_id":"<authenticated user>"}` and `Authorization: Bearer <control proof>`. The proof is a separate HS256 JWT with exactly `iss`, control `aud`, `op: "disconnect"`, numeric `widget_id`, `user_id`, integer `iat` and `exp`, and random `jti`. Its lifetime is at most 30 seconds by default. The path, body, and proof must agree. A browser identity JWT cannot authorize this request.

For a Phoenix backend, use `WebWidget.Integration.ControlProof.sign(connector_key, 12, user_id, issuer: "test-widget", audience: "zaq-web-widget:control")`. Other backends can sign the same claims. Reuse the **same proof** when retrying one disconnect operation: its `jti` returns the original cutoff. A new proof creates a new operation. ZAQ commits the replicated user cutoff before broadcasting to matching sessions. A new identity JWT issued in the cutoff's integer second may need to be minted in the next second.

## First smoke test

Verify the script and token endpoint return successfully, `#zaq-widget` appears once, a first question gets a `zaq:conversation` ID, and a page reload restores that ID. Test renewal with a short test lifetime, then call backend disconnect and confirm the refresh message. See [authenticated chat smoke](authenticated-chat.md) for operational checks and [host integration](host-integration.md) for package mounting.
