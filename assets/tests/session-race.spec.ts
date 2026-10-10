import { expect, test, type Route } from "@playwright/test";

test.afterEach(async ({ context }, testInfo) => {
  if (testInfo.status === testInfo.expectedStatus) return;
  const states = await Promise.all(context.pages().flatMap(page => page.frames())
    .filter(frame => frame.parentFrame())
    .map(frame => frame.evaluate(() => ({ path: location.pathname,
      connected: (window as any).liveSocket?.isConnected() || false,
      reason: document.getElementById("widget-session-error")?.dataset.reason || null,
    })).catch(() => ({ detached: true }))));
  await testInfo.attach("session-bootstrap-state", { contentType: "application/json", body: JSON.stringify(states) });
});

test("concurrent first loads of the same widget both retain a valid LiveView session", async ({ page, context }, testInfo) => {
  await page.goto("/widget/missing");

  const routes: Route[] = [];
  let pagesRequested!: () => void;
  const bothPagesRequested = new Promise<void>(resolve => { pagesRequested = resolve; });
  let releaseScripts!: () => void;
  const scriptsReleased = new Promise<void>(resolve => { releaseScripts = resolve; });

  // Both navigations reach the server without a pre-existing widget cookie.
  // Hold real page responses/scripts to force simultaneous session bootstrap.
  await page.route("**/widget/theme-dark", route => {
    routes.push(route);
    if (routes.length === 2) pagesRequested();
  });
  await page.route("**/web_widget/assets/app.js", async route => {
    await scriptsReleased;
    await route.continue();
  });

  const attempts: string[] = [];
  const bootstraps: { token: string; cookieIssued: boolean }[] = [];
  page.on("response", async response => {
    if (response.url().includes("/widget/theme-dark/session") && response.status() === 200) {
      const body = await response.json();
      bootstraps.push({ token: body.csrf_token,
        cookieIssued: !!(await response.headerValue("set-cookie"))?.includes("_web_widget_session=") });
    }
  });
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

    const responses = await Promise.all(routes.map(route => route.fetch({ headers: {
      ...route.request().headers(), "accept-encoding": "identity",
    } })));
    for (const [index, response] of responses.entries()) {
      expect(response.status()).toBe(200);
      expect(response.headers()["set-cookie"] || "").not.toContain("_web_widget_session=");
      await routes[index].fulfill({ response });
    }

    releaseScripts();
    await expect.poll(async () => {
      const frames = page.frames().filter(frame => frame.url().endsWith("/widget/theme-dark"));
      return Promise.all(frames.map(frame => frame.evaluate(() =>
        (window as any).liveSocket?.isConnected() || false)));
    }, { message: "Both iframe sessions must remain usable after their concurrent page responses" }).toEqual([true, true]);
    const handshakeTokens = await Promise.all(page.frames()
      .filter(frame => frame.url().endsWith("/widget/theme-dark"))
      .map(frame => frame.locator("meta[name='csrf-token']").getAttribute("content")));
    expect(handshakeTokens).toHaveLength(2);
    expect(handshakeTokens.every(token => bootstraps.some(bootstrap => bootstrap.token === token))).toBe(true);
    expect(bootstraps.filter(bootstrap => bootstrap.cookieIssued)).toHaveLength(1);
    const cookie = (await context.cookies("http://127.0.0.1:4019/widget/theme-dark"))
      .find(cookie => cookie.name === "_web_widget_session")!;
    expect(cookie.path).toBe("/widget/theme-dark");
    await page.evaluate(() => Promise.all(["race-first", "race-second"].map(id =>
      (window as any)[id].init({ user_id: id }))));
    const frames = page.frames().filter(frame => frame.url().endsWith("/widget/theme-dark"));
    const ids = await Promise.all(frames.map(frame => frame.locator("[data-phx-main]").getAttribute("id")));
    expect(new Set(ids).size).toBe(2);
    for (const frame of frames) {
      await frame.evaluate(() => new Promise<void>(resolve => (window as any).liveSocket.disconnect(resolve)));
      await frame.evaluate(() => (window as any).liveSocket.connect());
      await expect.poll(() => frame.evaluate(() => (window as any).liveSocket.isConnected())).toBe(true);
    }
    expect((await context.cookies("http://127.0.0.1:4019/widget/theme-dark"))
      .find(current => current.name === cookie.name)).toEqual(cookie);
  } finally {
    releaseScripts();
    const states = await Promise.all(page.frames()
      .filter(frame => frame.url().endsWith("/widget/theme-dark"))
      .map(async frame => ({
        iframe: await frame.frameElement().then(element => element.getAttribute("id")),
        connected: await frame.evaluate(() => (window as any).liveSocket?.isConnected() || false),
        failure: await frame.evaluate(() => document.getElementById("widget-session-error")?.dataset.reason || null),
      })));
    await testInfo.attach("same-widget-session-race", {
      contentType: "application/json",
      body: JSON.stringify({ handshakes: attempts.length, bootstraps: bootstraps.length,
        cookieWrites: bootstraps.filter(bootstrap => bootstrap.cookieIssued).length, states }, null, 2),
    });
  }
});

test.describe("cookie sharing across parent storage partitions", () => {
  test.use({ ignoreHTTPSErrors: true });

  test("different parent sites initialize independent cookie partitions", async ({ context, browserName }, testInfo) => {
    if (browserName !== "webkit") await context.grantPermissions(["local-network-access"]);
    const pages = await Promise.all([context.newPage(), context.newPage()]);
    const origin = "https://127.0.0.1:4023";
    const routes: Route[] = [];
    let firstRequested!: () => void;
    let secondRequested!: () => void;
    const firstRequest = new Promise<void>(resolve => { firstRequested = resolve; });
    const secondRequest = new Promise<void>(resolve => { secondRequested = resolve; });
    await context.route("**/partition-parent", route => route.fulfill({
      contentType: "text/html", body: "<!doctype html><body></body>",
    }));
    await context.route(origin + "/widget/cookie-none/session*", route => {
      if (new URL(route.request().url()).search) return route.continue();
      routes.push(route);
      if (routes.length === 1) firstRequested();
      if (routes.length === 2) secondRequested();
      if (routes.length > 2) return route.continue();
    });

    for (const [index, parent] of ["https://localhost:4023", origin].entries()) {
      await pages[index].goto(parent + "/partition-parent");
      await pages[index].evaluate(async origin => {
        const moduleUrl = origin + "/web_widget/assets/widget-client.js";
        const { createWidgetClient } = await import(moduleUrl);
        const iframe = document.createElement("iframe");
        iframe.id = "partition-widget";
        document.body.append(iframe);
        (window as any).partitionClient = createWidgetClient(iframe, origin + "/widget/cookie-none");
      }, origin);
    }
    await firstRequest;
    for (const page of pages) await expect(page.frameLocator("#partition-widget").locator("#widget-context")).toBeAttached();
    const frames = pages.map(page => page.frames().find(frame => frame.url() === origin + "/widget/cookie-none")!);
    const locks = await Promise.all(frames.map(frame => frame.evaluate(() => navigator.locks.query())));
    const firstLock = locks[0].held?.find(lock => lock.name === "web-widget-session:/widget/cookie-none/session");
    const secondLock = locks[1].held?.find(lock => lock.name === "web-widget-session:/widget/cookie-none/session");
    const partitioned = firstLock?.clientId !== secondLock?.clientId;

    if (partitioned) {
      await secondRequest;
      for (const route of routes) expect((await route.request().allHeaders()).cookie || "").not.toContain("_web_widget_session=");
      await routes[0].continue();
      await expect.poll(() => frames[0].evaluate(() => (window as any).liveSocket.isConnected())).toBe(true);
      // The second parent establishes its own partition after the first connects.
      await routes[1].continue();
    } else {
      await routes[0].continue();
      await secondRequest;
      await routes[1].continue();
    }

    for (const frame of frames) await expect.poll(() => frame.evaluate(() => (window as any).liveSocket.isConnected())).toBe(true);
    await Promise.all(pages.map((page, index) => page.evaluate(index =>
      (window as any).partitionClient.init({ user_id: "partition-" + index }), index)));
    const before = (await context.cookies(origin + "/widget/cookie-none"))
      .find(cookie => cookie.name === "_web_widget_session")!;
    const verifyCookies = await Promise.all(frames.map(frame => frame.evaluate(async () => {
      const url = document.querySelector<HTMLMetaElement>("meta[name='web-widget-session']")!.content;
      const response = await fetch(url + "?verify=1");
      return { status: response.status, token: (await response.json()).csrf_token as string };
    })));
    expect(verifyCookies.map(result => result.status)).toEqual([200, 200]);
    const partitionCookies = (await context.cookies(origin + "/widget/cookie-none"))
      .filter(cookie => cookie.name === "_web_widget_session" && cookie.path === "/widget/cookie-none");
    expect(partitionCookies).toHaveLength(2);
    expect(new Set(partitionCookies.map(cookie => cookie.value)).size).toBe(2);
    for (const frame of frames) {
      await frame.evaluate(() => new Promise<void>(resolve => (window as any).liveSocket.disconnect(resolve)));
      await frame.evaluate(() => (window as any).liveSocket.connect());
      await expect.poll(() => frame.evaluate(() => (window as any).liveSocket.isConnected())).toBe(true);
    }
    expect((await context.cookies(origin + "/widget/cookie-none"))
      .find(cookie => cookie.name === "_web_widget_session")).toEqual(before);
    await testInfo.attach("session-coordination-scope", {
      contentType: "application/json", body: JSON.stringify({ partitioned, bothConnected: true }),
    });
  });
});

test("unsupported session coordination fails explicitly without creating a cookie", async ({ page }) => {
  await page.addInitScript(() => Object.defineProperty(navigator, "locks", { value: undefined }));
  const requests: string[] = [];
  page.on("request", request => { if (request.url().includes("/widget/theme-dark/session")) requests.push(request.url()); });
  await page.goto("/widget/theme-dark");
  await expect(page.locator("#widget-session-error")).toHaveAttribute("data-reason", "session_coordination_unsupported");
  await expect(page.locator("#widget-session-error")).toBeVisible();
  expect(requests).toEqual([]);
});
