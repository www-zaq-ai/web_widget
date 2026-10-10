import { ViewHook } from "phoenix_live_view";
import {
  acceptConversationId, acceptIdentityToken, currentConversationId, postToParent, registerWidgetHandler, setPublicReady,
  unregisterWidgetHandler, waitForStylesheet,
} from "./widget-bootstrap";
import { connectionLost, connectionReady, connectionRevoked } from "./widget-connection";
import { widgetSessionEstablished, widgetSessionLost, widgetSessionStopped } from "./widget-session-connection";

type Settings = { theme: "auto" | "light" | "dark"; language: "en" | "fr" | "ar" };
// Module state belongs to this iframe document and survives LiveView remounts.
let sessionSettings: Settings = { theme: "light", language: "en" };
let hasSettings = false;
const nonblank = (value: unknown): value is string => typeof value === "string" && value.trim().length > 0;

export class WidgetContext extends ViewHook {
  private accepted = false;
  private connected = true;
  private connectionGeneration = 0;
  private contextTimer?: number;
  private allowedDomains: string[] = [];
  private queue = Promise.resolve();

  private reportError(reason: string) {
    if (this.el.dataset.authenticated === "true") {
      console.error(`[WebWidget] ${reason} Obtain a fresh identity_token from your authenticated backend and call zaq.widget.connect. Never send the connector key to the browser.`);
      return;
    }
    console.error(`[WebWidget] ${reason} The chat requires a valid user_id. In the parent page, listen for "zaq.widget.ready", verify event.source === iframe.contentWindow and event.origin === the widget origin, then call iframe.contentWindow.postMessage({ type: "zaq.widget.init", user_id: "user_123", prompt_context: "Current page: /billing", conversation_id: null }, widgetOrigin). prompt_context must be a string or null. Use the exact widget origin; the parent origin must be listed in the widget’s allowed_domains.`);
  }

  private receiveContext = (event: MessageEvent) => {
    if (window.parent === window || event.source !== window.parent || !this.allowedDomains.includes(event.origin)) return;
    if (!["zaq.widget.connect", "zaq.widget.init", "zaq.widget.context.update", "zaq.widget.settings.update", "zaq.widget.settings.get", "zaq.widget.auth.status"].includes(event.data?.type)) return;
    this.queue = this.queue.then(() => this.receive(event));
  };

  private async receive(event: MessageEvent) {
    const data = event.data;
    let failureReason: string | undefined;
    try {
      let reply: any;
      if (data.type === "zaq.widget.auth.status") {
        this.respond(event, await this.dispatch("widget.auth.status", {}));
        return;
      }
      if (data.type === "zaq.widget.context.update") {
        if (Object.keys(data).some(key => !["type", "request_id", "conversation_id", "prompt_context"].includes(key))) {
          throw new Error("Unsupported context field.");
        }
        const reply = await this.dispatch("widget.context.update", {
          conversation_id: data.conversation_id ?? null,
          prompt_context: data.prompt_context ?? null,
        });
        this.respond(event, reply);
        return;
      }
      if (data.type === "zaq.widget.connect" || data.type === "zaq.widget.init") {
        const authenticated = this.el.dataset.authenticated === "true";
        if (authenticated && !nonblank(data.identity_token)) throw new Error("Missing identity_token in zaq.widget.connect.");
        if (!authenticated && !nonblank(data.user_id)) throw new Error("Missing or invalid user_id in zaq.widget.init.");
        const allowed = authenticated
          ? ["type", "request_id", "identity_token"]
          : ["type", "request_id", "user_id", "conversation_id", "prompt_context"];
        if (Object.keys(data).some(key => !allowed.includes(key))) throw new Error("Unsupported init field. Sign initialization context in the token; use updateSettings for presentation.");
        if (authenticated) {
          reply = await this.dispatch(this.accepted ? "widget.auth.renew" : "widget.context", { identity_token: data.identity_token });
        } else {
          const conversation_id = data.conversation_id ?? null;
          const prompt_context = data.prompt_context ?? null;
          if (conversation_id !== null && !nonblank(conversation_id)) throw new Error("conversation_id must be a nonblank string or null.");
          if (prompt_context !== null && typeof prompt_context !== "string") throw new Error("Invalid prompt_context: objects and arrays are not supported.");
          reply = await this.dispatch("widget.context", { user_id: data.user_id, conversation_id, prompt_context });
        }
        if (reply.ok) {
          if (authenticated) acceptIdentityToken(data.identity_token);
          this.accepted = true;
          window.clearTimeout(this.contextTimer);
        }
      } else {
        reply = await this.dispatch(data.type === "zaq.widget.settings.get" ? "widget.settings.get" : "widget.settings.update", { settings: data.settings });
      }
      if (!reply.ok) {
        failureReason = reply.reason;
        throw new Error(reply.error || reply.reason || "Widget request rejected.");
      }
      if (reply.settings) {
        sessionSettings = reply.settings;
        hasSettings = true;
        await this.applyDocumentSettings();
      }
      if (reply.expires_at) {
        postToParent("zaq.widget.authenticated", this.metadata(reply));
        void this.restoreAndAnnounce();
      }
      this.respond(event, { ok: true, settings: sessionSettings, ...this.metadata(reply) });
    } catch (error) {
      const message = error instanceof Error ? error.message : "Widget request failed.";
      this.respond(event, { ok: false, error: message, reason: failureReason });
      if (data.type === "zaq.widget.init" || data.type === "zaq.widget.connect") this.reportError(message);
    }
  }

  private respond(event: MessageEvent, reply: object) {
    if (nonblank(event.data.request_id)) window.parent.postMessage({ type: "zaq.widget.result", request_id: event.data.request_id, ...reply }, event.origin);
  }

  private metadata(reply: any) {
    return {
      expires_at: reply.expires_at,
      refresh_at: reply.refresh_at,
      server_time: reply.server_time,
      credential_id: reply.credential_id,
    };
  }

  private dispatch(name: string, params: object): Promise<any> {
    return new Promise((resolve, reject) => {
      const timer = window.setTimeout(() => reject(new Error("Widget request timed out.")), 10000);
      try {
        this.pushEvent(name, params, reply => { window.clearTimeout(timer); resolve(reply); });
      } catch (error) {
        window.clearTimeout(timer);
        reject(error);
      }
    });
  }

  private async applyDocumentSettings() {
    document.documentElement.lang = sessionSettings.language;
    document.documentElement.dir = sessionSettings.language === "ar" ? "rtl" : "ltr";
    if (document.getElementById("widget-state")?.dataset.contextReceived !== "true") return;
    // React applies LiveView props asynchronously. Acknowledge after its commit.
    await new Promise<void>((resolve, reject) => {
      const matches = () => {
        const root = document.querySelector<HTMLElement>(".zaq-widget");
        const conversation = currentConversationId();
        return root?.dataset.language === sessionSettings.language && root?.dataset.theme === sessionSettings.theme &&
          (!conversation || this.el.dataset.authenticated !== "true" || root.dataset.conversationId === conversation);
      };
      if (matches()) return resolve();
      const observer = new MutationObserver(() => {
        if (matches()) { window.clearTimeout(timer); observer.disconnect(); resolve(); }
      });
      const timer = window.setTimeout(() => { observer.disconnect(); reject(new Error("Widget render timed out.")); }, 5000);
      observer.observe(document.body, { subtree: true, childList: true, attributes: true });
    });
  }

  mounted() {
    widgetSessionEstablished();
    this.allowedDomains = JSON.parse(this.el.dataset.allowedDomains || "[]");
    this.accepted = this.el.dataset.authorized === "true";
    this.handleEvent("widget.conversation", data => {
      if (this.el.dataset.authenticated === "true" && nonblank(data.conversation_id)) {
        acceptConversationId(data.conversation_id);
      }
      postToParent("zaq.widget.conversation", data);
    });
    this.handleEvent("widget.authentication.accepted", data => {
      this.accepted = true;
      postToParent("zaq.widget.authenticated", this.metadata(data));
      void this.restoreAndAnnounce();
    });
    this.handleEvent("widget.authentication.required", data => {
      this.accepted = false;
      setPublicReady(false);
      postToParent("zaq.widget.authentication.required", { reason: data.reason || "expired" });
      if (data.reason === "backend_revoked") {
        widgetSessionStopped();
        connectionRevoked();
        const alert = document.createElement("div");
        alert.id = "widget-backend-revoked";
        alert.setAttribute("role", "alert");
        alert.textContent = "Refresh the page to reconnect.";
        alert.style.cssText = "position:fixed;inset:0;z-index:2147483647;display:grid;place-items:center;background:#fff;color:#111;font:16px system-ui;text-align:center;padding:24px";
        document.body.append(alert);
        window.setTimeout(() => (window as any).liveSocket?.disconnect(), 0);
      }
    });
    registerWidgetHandler(this.receiveContext);
    if (this.accepted) {
      const expires_at = Number(this.el.dataset.authExpiresAt);
      const refresh_at = Number(this.el.dataset.authRefreshAt);
      const server_time = Number(this.el.dataset.authServerTime);
      if (Number.isFinite(expires_at) && expires_at > 0) {
        postToParent("zaq.widget.authenticated", {
          expires_at, refresh_at, server_time,
          credential_id: this.el.dataset.authCredentialId,
        });
      }
    }
    void this.restoreAndAnnounce();
  }

  disconnected() {
    widgetSessionLost();
    this.connected = false;
    this.connectionGeneration++;
    if (this.el.dataset.authenticated === "true") this.accepted = false;
    connectionLost();
    setPublicReady(false);
    postToParent("zaq.widget.disconnected", { reason: "network" });
  }

  reconnected() {
    widgetSessionEstablished();
    this.connected = true;
    if (this.el.dataset.authenticated === "true") this.accepted = this.el.dataset.authorized === "true";
    postToParent("zaq.widget.bootstrap.ready");
    void this.restoreAndAnnounce();
  }

  private async restoreAndAnnounce() {
    // Restore preferences before the parent's repeated bootstrap can run.
    if (hasSettings) {
      try { await this.dispatch("widget.settings.update", { settings: sessionSettings }); }
      catch { /* The parent can retry once readiness is announced. */ }
    }
    this.announceReady();
  }

  destroyed() {
    this.connected = false;
    this.connectionGeneration++;
    window.clearTimeout(this.contextTimer);
    unregisterWidgetHandler(this.receiveContext);
  }

  private async announceReady() {
    const generation = this.connectionGeneration;
    if (!this.connected) return;
    if (this.el.dataset.authenticated === "true" && !this.accepted) return;
    await waitForStylesheet();
    if (this.el.dataset.authenticated === "true") {
      try { await this.applyDocumentSettings(); }
      catch { return; }
    }
    if (!this.connected || generation !== this.connectionGeneration ||
        (this.el.dataset.authenticated === "true" && !this.accepted)) return;
    window.clearTimeout(this.contextTimer);
    if (window.parent === window) {
      this.reportError("No embedding parent found. Open /widget-demo or embed /widget in an iframe.");
      return;
    }
    if (!this.accepted) this.contextTimer = window.setTimeout(() => this.reportError("No valid user_id received within 5 seconds of zaq.widget.ready; the chat remains hidden. Send valid context to continue."), 5000);
    connectionReady();
    setPublicReady(true);
  }
}
