import { expect, test, type Route } from "@playwright/test";

test("concurrent first loads of the same widget both retain a valid LiveView session", async ({ page, context }, testInfo) => {
  await page.goto("/widget/missing");

  const routes: Route[] = [];
  let pagesRequested!: () => void;
  const bothPagesRequested = new Promise<void>(resolve => { pagesRequested = resolve; });
  let releaseScripts!: () => void;
  const scriptsReleased = new Promise<void>(resolve => { releaseScripts = resolve; });

  // Both navigations reach the server without a pre-existing widget cookie.
  // Hold the real responses and scripts so both cookies arrive before either handshake.
  await page.route("**/widget/theme-dark", route => {
    routes.push(route);
    if (routes.length === 2) pagesRequested();
  });
  await page.route("**/web_widget/assets/app.js", async route => {
    await scriptsReleased;
    await route.continue();
  });

  const attempts: string[] = [];
  page.on("websocket", socket => {
    if (socket.url().includes("/widget/theme-dark/live/websocket")) {
      attempts.push(new URL(socket.url()).searchParams.get("_csrf_token") || "");
    }
  });

  await page.evaluate(async () => {
    const moduleUrl = location.origin + "/web_widget/assets/widget-client.js";
    const { createWidgetClient } = await import(moduleUrl);
    for (const id of ["race-first", "race-second"]) {
      const iframe = document.createElement("iframe");
      iframe.id = id;
      document.body.append(iframe);
      (window as any)[id] = createWidgetClient(iframe, location.origin + "/widget/theme-dark");
    }
  });

  try {
    await bothPagesRequested;
    for (const route of routes) {
      expect((await route.request().allHeaders()).cookie || "").not.toContain("_web_widget_session=");
    }

    const responses = await Promise.all(routes.map(route => route.fetch()));
    const tokens: string[] = [];
    const cookies: string[] = [];
    for (const [index, response] of responses.entries()) {
      expect(response.status()).toBe(200);
      const body = await response.text();
      const token = body.match(/<meta[^>]*name="csrf-token"[^>]*content="([^"]+)"/);
      expect(token).not.toBeNull();
      tokens.push(token![1]);
      const cookie = response.headers()["set-cookie"].match(/_web_widget_session=([^;]+)/);
      expect(cookie).not.toBeNull();
      cookies.push(cookie![1]);
      await routes[index].fulfill({ response });
      await expect.poll(async () => (await context.cookies("http://127.0.0.1:4019/widget/theme-dark"))
        .find(cookie => cookie.name === "_web_widget_session")?.value).toBe(cookies[index]);
    }
    expect(cookies[0]).not.toBe(cookies[1]);

    releaseScripts();
    await expect.poll(() => new Set(attempts).size).toBe(2);
    expect(attempts).toEqual(expect.arrayContaining(tokens));
    await expect.poll(async () => {
      const frames = page.frames().filter(frame => frame.url().endsWith("/widget/theme-dark"));
      return Promise.all(frames.map(frame => frame.evaluate(() =>
        (window as any).liveSocket?.isConnected() || false)));
    }, { message: "Both iframe sessions must remain usable after their concurrent page responses" }).toEqual([true, true]);
  } finally {
    releaseScripts();
    const states = await Promise.all(page.frames()
      .filter(frame => frame.url().endsWith("/widget/theme-dark"))
      .map(async frame => ({
        iframe: await frame.frameElement().then(element => element.getAttribute("id")),
        connected: await frame.evaluate(() => (window as any).liveSocket?.isConnected() || false),
      })));
    await testInfo.attach("same-widget-session-race", {
      contentType: "application/json",
      body: JSON.stringify({ distinctHandshakeTokens: new Set(attempts).size, states }, null, 2),
    });
  }
});
