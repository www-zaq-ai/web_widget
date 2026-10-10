import { expect, test } from "@playwright/test";
import { readFileSync } from "node:fs";
import ts from "typescript";

test("script stylesheet reaches the cross-origin iframe, survives reload, and resets on remount", async ({ page }) => {
  await page.route("http://127.0.0.1:4019/brand.css", route => route.fulfill({
    contentType: "text/css", body: ":root { --zaq-widget-composer-background: #302640; }",
  }));
  await page.goto("/widget/missing");
  await page.evaluate(() => new Promise<void>(resolve => {
    const div = document.createElement("div");
    div.id = "chat";
    div.style.height = "600px";
    document.body.append(div);
    const script = document.createElement("script");
    script.src = "http://127.0.0.1:4020/web_widget/assets/embed.js";
    script.dataset.widgetId = "42";
    script.setAttribute("iframe-location-id", "#chat");
    script.setAttribute("stylesheet-url", "/brand.css");
    script.onload = () => resolve();
    document.body.append(script);
  }));
  await page.evaluate(() => window.zaq.widget.init({ user_id: "css-user" }));
  const widget = page.frameLocator("#chat > iframe");
  await expect(widget.locator(".zaq-composer")).toHaveCSS("background-color", "rgb(48, 38, 64)");
  const link = widget.locator("#zaq-widget-stylesheet");
  await expect(link).toHaveAttribute("href", "http://127.0.0.1:4019/brand.css");
  // Repeated readiness must not accumulate links or fetch a different URL.
  await page.evaluate(() => window.zaq.widget.mount("http://127.0.0.1:4020/widget/42", "#chat", "/brand.css"));
  await expect(link).toHaveCount(1);
  await page.frames().find(frame => frame.url().endsWith("/widget/42"))!.evaluate(() => location.reload());
  await expect(widget.locator(".zaq-composer")).toHaveCSS("background-color", "rgb(48, 38, 64)");
  await expect(link).toHaveCount(1);
  await page.evaluate(async () => {
    window.zaq.widget.dispose();
    window.zaq.widget.mount("http://127.0.0.1:4020/widget/42", "#chat");
    await window.zaq.widget.init({ user_id: "css-user" });
  });
  await expect(widget.locator(".zaq-composer")).toHaveCSS("background-color", "rgb(255, 255, 255)");
  await expect(link).toHaveCount(0);
});

test("public ready waits for a stylesheet delivered during the presentation handshake", async ({ page }) => {
  let stylesheetRequested = false;
  let releaseStylesheet: (() => void) | undefined;
  await page.route("**/delayed-brand.css", async route => {
    stylesheetRequested = true;
    await new Promise<void>(resolve => { releaseStylesheet = resolve; });
    await route.fulfill({ contentType: "text/css", body: ":root { --zaq-widget-composer-background: #302640; }" });
  });
  await page.goto("/widget/missing");
  await page.evaluate(() => {
    (window as any).readyCount = 0;
    const iframe = document.createElement("iframe");
    iframe.src = "http://127.0.0.1:4020/widget/42";
    window.addEventListener("message", event => {
      if (event.source !== iframe.contentWindow || event.origin !== "http://127.0.0.1:4020") return;
      if (event.data?.type === "zaq.widget.bootstrap.ready") {
        window.setTimeout(() => iframe.contentWindow?.postMessage({
          type: "zaq.widget.stylesheet", url: "http://127.0.0.1:4019/delayed-brand.css",
        }, "http://127.0.0.1:4020"), 30);
      }
      if (event.data?.type === "zaq.widget.ready") (window as any).readyCount++;
    });
    document.body.append(iframe);
  });
  await expect.poll(() => stylesheetRequested).toBe(true);
  try {
    await page.waitForTimeout(180);
    expect(await page.evaluate(() => (window as any).readyCount)).toBe(0);
  } finally {
    releaseStylesheet?.();
  }
  await expect.poll(() => page.evaluate(() => (window as any).readyCount)).toBe(1);
});

test("invalid stylesheet attributes fail before mounting", async ({ page }) => {
  await page.goto("/widget/missing");
  await page.addScriptTag({ url: "http://127.0.0.1:4020/web_widget/assets/embed.js" });
  for (const url of ["", "javascript:alert(1)", "data:text/css,body{}", "https://user:pass@example.com/style.css", "https://exa mple.com/a.css"]) {
    expect(await page.evaluate(url => {
      try { window.zaq.widget.mount("http://127.0.0.1:4020/widget/42", undefined, url); return false; }
      catch { return true; }
    }, url)).toBe(true);
  }
  await expect(page.locator("iframe")).toHaveCount(0);
});

test("runtime config is ignored and iframe rejects invalid or forged stylesheet messages", async ({ page }) => {
  await page.goto("/widget-demo?widget_id=theme-custom");
  const widget = page.frameLocator("#zaq-widget");
  await expect(widget.locator(".zaq-composer")).toBeVisible();
  await expect(widget.locator('link[href*="custom-widget.css"]')).toHaveCount(0);
  const frame = page.frames().find(frame => frame.url().includes("/widget/theme-custom"))!;
  await frame.evaluate(() => {
    for (const event of [
      { source: window, origin: "http://127.0.0.1:4019", url: "https://example.com/forged.css" },
      { source: window.parent, origin: "https://untrusted.example", url: "https://example.com/forged.css" },
      { source: window.parent, origin: "http://127.0.0.1:4019", url: "javascript:alert(1)" },
    ]) {
      window.dispatchEvent(new MessageEvent("message", {
        source: event.source, origin: event.origin, data: { type: "zaq.widget.stylesheet", url: event.url },
      }));
    }
  });
  await expect(widget.locator("#zaq-widget-stylesheet")).toHaveCount(0);
  await expect(widget.locator(".zaq-composer")).toHaveCSS("background-color", "rgb(255, 255, 255)");
});

for (const change of ["duplicate", "replace", "remove", "error", "timeout"] as const) {
  test(`pending stylesheet ${change} preserves authentication and readiness ordering`, async ({ page, request }) => {
    const held = new Map<string, { release: () => void; done: Promise<void> }>();
    const requests: string[] = [];
    await page.route("**/held-*.css", async route => {
      const url = route.request().url();
      requests.push(url);
      let release!: () => void;
      let done!: () => void;
      const gate = new Promise<void>(resolve => { release = resolve; });
      const completed = new Promise<void>(resolve => { done = resolve; });
      held.set(url, { release, done: completed });
      await gate;
      if (change === "error") await route.abort();
      else await route.fulfill({ contentType: "text/css", body: ":root { --zaq-widget-composer-background: #302640; }" });
      done();
    });
    const identity = async () => (await (await request.get("http://127.0.0.1:4021/identity", {
      params: { user_id: `css-${change}` },
    })).json()).identity_token;
    const token = await identity();
    await page.goto("/widget/missing");
    const a = "http://127.0.0.1:4019/held-a.css";
    const b = "http://127.0.0.1:4019/held-b.css";
    await page.evaluate(({ token, a }) => {
      const iframe = document.createElement("iframe");
      iframe.id = "css-widget";
      iframe.src = `http://127.0.0.1:4020/widget/420#identity_token=${token}`;
      (window as any).cssEvents = [];
      (window as any).cssURL = a;
      window.addEventListener("message", event => {
        if (event.source !== iframe.contentWindow || event.origin !== "http://127.0.0.1:4020") return;
        (window as any).cssEvents.push(event.data);
        if (event.data.type === "zaq.widget.bootstrap.ready") iframe.contentWindow!.postMessage({
          type: "zaq.widget.stylesheet", url: (window as any).cssURL,
        }, "http://127.0.0.1:4020");
      });
      document.body.append(iframe);
    }, { token, a });
    const widget = page.frameLocator("#css-widget");
    const ready = () => page.evaluate(() => (window as any).cssEvents.filter((e: any) => e.type === "zaq.widget.ready").length);
    await expect.poll(() => held.has(a)).toBe(true);
    await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true");
    expect(await ready()).toBe(0);
    await page.clock.install();
    try {
      // Probe while CSS is still pending. A probe after removal may legitimately
      // replay the ready transition rather than test pending-readiness ordering.
      const bootstrap = () => page.evaluate(() => (window as any).cssEvents.filter((e: any) => e.type === "zaq.widget.bootstrap.ready").length);
      const beforeProbe = await bootstrap();
      await page.evaluate(() => {
        (document.getElementById("css-widget") as HTMLIFrameElement).contentWindow!
          .postMessage({ type: "zaq.widget.ready.request" }, "http://127.0.0.1:4020");
      });
      await expect.poll(bootstrap).toBe(beforeProbe + 1);
      expect(await ready()).toBe(0);
      const fresh = await identity();
      await page.evaluate(({ change, a, b, fresh }) => {
        const frame = (document.getElementById("css-widget") as HTMLIFrameElement).contentWindow!;
        const url = change === "replace" ? b : change === "remove" ? null : a;
        (window as any).cssURL = url;
        for (let i = 0; i < 3; i++) frame.postMessage({ type: "zaq.widget.stylesheet", url }, "http://127.0.0.1:4020");
        frame.postMessage({ type: "zaq.widget.connect", identity_token: fresh, request_id: "renew-css" }, "http://127.0.0.1:4020");
      }, { change, a, b, fresh });
      await expect.poll(() => page.evaluate(() => (window as any).cssEvents.some((e: any) => e.request_id === "renew-css" && e.ok))).toBe(true);
      await page.clock.runFor(250);
      if (change === "remove") {
        await expect.poll(ready).toBe(1);
        await expect(widget.locator("#zaq-widget-stylesheet")).toHaveCount(0);
      } else if (change === "timeout") {
        expect(await ready()).toBe(0);
        await expect.poll(ready, { timeout: 5000 }).toBe(1);
      } else {
        expect(await ready()).toBe(0);
        held.get(a)!.release();
        await held.get(a)!.done;
        if (change === "replace") {
          await expect.poll(() => held.has(b)).toBe(true);
          expect(await ready()).toBe(0);
          held.get(b)!.release();
          await held.get(b)!.done;
        }
        await expect.poll(ready).toBe(1);
        if (change !== "error") await expect(widget.locator(".zaq-composer")).toHaveCSS("background-color", "rgb(48, 38, 64)");
        await expect(widget.locator("#zaq-widget-stylesheet")).toHaveCount(1);
      }
      expect(requests.filter(url => url === a)).toHaveLength(1);
      expect(await ready()).toBe(1);
      // Late-attaching parents must still receive an explicit already-ready reply.
      const afterReady = await bootstrap();
      await page.evaluate(() => {
        (document.getElementById("css-widget") as HTMLIFrameElement).contentWindow!
          .postMessage({ type: "zaq.widget.ready.request" }, "http://127.0.0.1:4020");
      });
      await expect.poll(bootstrap).toBe(afterReady + 1);
      await expect.poll(ready).toBe(2);
      await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true");
    } finally {
      for (const response of held.values()) response.release();
    }
  });
}


test("bootstrap waiters follow the active stylesheet across duplicate and replacement decisions", async ({ page }) => {
  const source = readFileSync(new URL("../js/widget-stylesheet.ts", import.meta.url), "utf8") +
    readFileSync(new URL("../js/widget-bootstrap.ts", import.meta.url), "utf8").replace(/import .*from "\.\/widget-stylesheet";/, "");
  const code = ts.transpileModule(source.replace(/export /g, "") +
    "\n(window as any).waitForStylesheet = waitForStylesheet;", { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText;
  await page.goto("/widget/missing");
  await page.route("**/unit-*.css", () => {});
  await page.evaluate(() => {
    const frame = document.createElement("iframe");
    frame.id = "bootstrap-unit";
    frame.srcdoc = '<div id="widget-context" data-allowed-domains=\'["http://127.0.0.1:4019"]\'></div>';
    document.body.append(frame);
  });
  await expect.poll(() => page.frames().some(f => f.url() === "about:srcdoc")).toBe(true);
  const frame = page.frames().find(f => f.url() === "about:srcdoc")!;
  await frame.waitForSelector("#widget-context", { state: "attached" });
  await frame.addScriptTag({ content: code });
  const decision = async (url: string | null) => {
    await frame.evaluate(url => new Promise<void>(resolve => {
      window.addEventListener("message", () => resolve(), { once: true });
      window.dispatchEvent(new MessageEvent("message", { source: window.parent, origin: "http://127.0.0.1:4019", data: { type: "zaq.widget.stylesheet", url } }));
    }), url);
  };
  await decision("http://127.0.0.1:4019/unit-a.css");
  await frame.evaluate(() => { (window as any).settled = 0; void (window as any).waitForStylesheet().then(() => (window as any).settled++); });
  await decision("http://127.0.0.1:4019/unit-a.css");
  await frame.evaluate(() => { void (window as any).waitForStylesheet().then(() => (window as any).settled++); });
  expect(await frame.evaluate(() => (window as any).settled)).toBe(0);
  await frame.evaluate(() => { (window as any).obsoleteLink = document.getElementById("zaq-widget-stylesheet"); });
  await decision("http://127.0.0.1:4019/unit-b.css");
  await frame.evaluate(() => (window as any).obsoleteLink.dispatchEvent(new Event("load")));
  expect(await frame.evaluate(() => (window as any).settled)).toBe(0);
  await frame.locator("#zaq-widget-stylesheet").dispatchEvent("load");
  await expect.poll(() => frame.evaluate(() => (window as any).settled)).toBe(2);
  await decision("http://127.0.0.1:4019/unit-b.css");
  await frame.evaluate(() => (window as any).waitForStylesheet());
  await expect(frame.locator("#zaq-widget-stylesheet")).toHaveCount(1);
});
