import { createWidgetClient, type WidgetInit, type DemoWidgetInit, type WidgetSettings, type WidgetContextUpdate, type TokenProvider } from "./widget-client";
import { stylesheetURL } from "./widget-stylesheet";

function endpointProvider(path: string): TokenProvider {
  const url = new URL(path, document.baseURI);
  if (url.origin !== window.location.origin || !["https:", "http:"].includes(url.protocol) ||
      url.username || url.password) throw new Error("data-token-url must be a parent same-origin HTTP(S) URL.");
  return async signal => {
    const response = await fetch(url, {
      method: "GET", credentials: "same-origin", cache: "no-store", signal,
      headers: { Accept: "application/json" },
    });
    if (!response.ok) throw new Error("Widget token endpoint failed.");
    if (!response.headers.get("cache-control")?.toLowerCase().includes("no-store")) {
      throw new Error("Widget token endpoint must return Cache-Control: no-store.");
    }
    const body = await response.json();
    if (typeof body?.identity_token !== "string" || !body.identity_token.trim()) {
      throw new Error("Widget token endpoint did not return identity_token.");
    }
    return body.identity_token;
  };
}

function createEmbed() {
  let client: ReturnType<typeof createWidgetClient> | undefined;
  let cleanup: (() => void) | undefined;
  let ownedFrame: HTMLIFrameElement | undefined;
  let mountedFrame: HTMLIFrameElement | undefined;
  let container: HTMLDivElement | undefined;
  let stylesheet: string | null = null;
  let tokenProvider: TokenProvider | undefined;
  let initialAbort: AbortController | undefined;

  function connect() {
    if (client) return client;
    const iframe = mountedFrame || document.getElementById("zaq-widget");
    if (!(iframe instanceof HTMLIFrameElement) || !iframe.getAttribute("src")) {
      throw new Error('Add an iframe with id="zaq-widget" and a widget src before calling zaq.widget.connect().');
    }
    const origin = new URL(iframe.src).origin;
    const originalStyle = iframe.getAttribute("style");
    const originalTitle = iframe.getAttribute("title");
    const originalMode = iframe.getAttribute("data-mode");
    const originalOverflow = document.documentElement.style.overflow;
    const defaults = container ? {
      display: "block", position: "static", width: "100%", height: "100%",
      border: "0", background: "transparent", colorScheme: "light dark",
    } : {
      position: "fixed", bottom: "0", left: "0", width: "100%", height: "180px",
      border: "0", background: "transparent", colorScheme: "light dark", zIndex: "1000",
    };
    for (const [key, value] of Object.entries(defaults)) {
      const property = key as keyof typeof defaults;
      if (!iframe.style[property]) iframe.style[property] = value;
    }
    if (!originalTitle) iframe.title = "ZAQ widget";
    const resize = (event: MessageEvent) => {
      if (event.source !== iframe.contentWindow || event.origin !== origin) return;
      const data = event.data;
      if (data?.type === "zaq.widget.bootstrap.ready") {
        iframe.contentWindow?.postMessage({ type: "zaq.widget.stylesheet", url: stylesheet }, origin);
        return;
      }
      if (data?.type !== "zaq.widget.resize") return;
      if (container) {
        if (data.mode === "conversation" || (data.mode === "launcher" && Number.isFinite(data.height))) {
          iframe.dataset.mode = data.mode;
        }
        return;
      }
      if (data.mode === "conversation") {
        iframe.dataset.mode = "conversation";
        iframe.style.height = "100dvh";
        document.documentElement.style.overflow = "hidden";
      } else if (data.mode === "launcher" && Number.isFinite(data.height)) {
        iframe.dataset.mode = "launcher";
        iframe.style.height = `${Math.min(260, Math.max(96, data.height))}px`;
        document.documentElement.style.overflow = originalOverflow;
      }
    };
    window.addEventListener("message", resize);
    cleanup = () => {
      window.removeEventListener("message", resize);
      if (!container) document.documentElement.style.overflow = originalOverflow;
      if (originalStyle === null) iframe.removeAttribute("style");
      else iframe.setAttribute("style", originalStyle);
      if (originalMode === null) iframe.removeAttribute("data-mode");
      else iframe.setAttribute("data-mode", originalMode);
      if (originalTitle === null) iframe.removeAttribute("title");
      else iframe.setAttribute("title", originalTitle);
    };
    try {
      const initialToken = new URL(iframe.src).hash
        ? new URLSearchParams(new URL(iframe.src).hash.slice(1)).get("identity_token") || undefined
        : undefined;
      client = createWidgetClient(iframe, iframe.src, { tokenProvider, initialToken });
    } catch (error) {
      cleanup();
      cleanup = undefined;
      throw error;
    }
    return client;
  }

  return {
    mount(url: string, selector?: string, stylesheetUrl?: string, initialToken?: string) {
      const target = new URL(url);
      if (initialToken) target.hash = new URLSearchParams({ identity_token: initialToken }).toString();
      const nextStylesheet = stylesheetUrl === undefined ? null : stylesheetURL(stylesheetUrl, document.baseURI);
      if (!["https:", "http:"].includes(target.protocol)) throw new Error("Widget URL must use HTTP(S).");
      let destination: HTMLDivElement | undefined;
      if (selector !== undefined) {
        let element: Element | null;
        try { element = document.querySelector(selector); }
        catch { throw new Error("Invalid iframe-location-id selector."); }
        if (!(element instanceof HTMLDivElement)) {
          throw new Error("iframe-location-id must select an existing div.");
        }
        destination = element;
      }
      if (mountedFrame && container !== destination) {
        throw new Error("Widget is already mounted in a different location.");
      }
      const frameId = destination?.id === "zaq-widget" ? "zaq-widget-frame" : "zaq-widget";
      const existing = mountedFrame || document.getElementById(frameId);
      const sameFrame = existing instanceof HTMLIFrameElement &&
        new URL(existing.src).origin + new URL(existing.src).pathname === target.origin + target.pathname;
      if (existing && !sameFrame) {
        throw new Error(`A different widget already uses #${frameId}.`);
      }
      if (existing && destination && existing.parentElement !== destination) {
        throw new Error("Widget is already mounted in a different location.");
      }
      container = destination;
      stylesheet = nextStylesheet;
      if (!existing) {
        ownedFrame = document.createElement("iframe");
        ownedFrame.id = frameId;
        ownedFrame.src = target.href;
        (container || document.body).append(ownedFrame);
      }
      mountedFrame = (existing as HTMLIFrameElement | null) || ownedFrame;
      connect();
      mountedFrame?.contentWindow?.postMessage({ type: "zaq.widget.ready.request" }, target.origin);
    },
    async mountAuthenticated(url: string, selector?: string, stylesheetUrl?: string) {
      if (!tokenProvider) throw new Error("Set a token provider before authenticated mounting.");
      initialAbort?.abort();
      const controller = new AbortController();
      initialAbort = controller;
      const token = await tokenProvider(controller.signal);
      if (controller.signal.aborted) return;
      this.mount(url, selector, stylesheetUrl, token);
    },
    setTokenProvider(provider: TokenProvider) {
      tokenProvider = provider;
      client?.setTokenProvider(provider);
    },
    isReady() { return client?.isReady() || false; },
    async connect(context?: WidgetInit) { return connect().connect(context); },
    async init(context: WidgetInit | DemoWidgetInit) { return connect().init(context); },
    async updateSettings(settings: Partial<WidgetSettings>) { return connect().updateSettings(settings); },
    async updateContext(context: WidgetContextUpdate) { return connect().updateContext(context); },
    async getSettings() { return connect().getSettings(); },
    dispose() {
      initialAbort?.abort();
      initialAbort = undefined;
      client?.dispose();
      cleanup?.();
      ownedFrame?.remove();
      ownedFrame = undefined;
      client = undefined;
      cleanup = undefined;
      mountedFrame = undefined;
      container = undefined;
      stylesheet = null;
    },
  };
}

declare global {
  interface Window {
    zaq: { widget: ReturnType<typeof createEmbed> };
  }
}

window.zaq = window.zaq || {} as Window["zaq"];
window.zaq.widget = window.zaq.widget || createEmbed();

// A bare embed.js include retains the manual iframe API.
const script = document.currentScript;
if (script instanceof HTMLScriptElement && script.hasAttribute("data-widget-id")) {
  const widgetId = script.dataset.widgetId || "";
  if (widgetId.length > 200 || !/^[a-zA-Z0-9][a-zA-Z0-9_-]*$/.test(widgetId)) {
    throw new Error("Invalid widget ID.");
  }
  const target = new URL(script.dataset.widgetUrl || `/widget/${widgetId}`, script.src);
  if (target.origin !== new URL(script.src).origin || target.username || target.password ||
      target.search || target.hash || !["https:", "http:"].includes(target.protocol) ||
      !target.pathname.endsWith(`/${widgetId}`)) {
    throw new Error("data-widget-url must select this widget on the loader origin.");
  }
  const url = target.href;
  const selector = script.getAttribute("iframe-location-id") ?? undefined;
  const stylesheet = script.getAttribute("stylesheet-url") ?? undefined;
  const tokenUrl = script.getAttribute("data-token-url");
  if (tokenUrl) window.zaq.widget.setTokenProvider(endpointProvider(tokenUrl));
  const mount = () => {
    if (tokenUrl) void window.zaq.widget.mountAuthenticated(url, selector, stylesheet).catch(error => {
      console.error("[WebWidget] Authenticated mount failed.", error);
    });
    else window.zaq.widget.mount(url, selector, stylesheet);
  };
  if (document.body && (selector === undefined || document.readyState !== "loading")) mount();
  else document.addEventListener("DOMContentLoaded", mount, { once: true });
}
