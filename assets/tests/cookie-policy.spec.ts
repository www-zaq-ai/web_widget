import { expect, test } from "@playwright/test";

// Local HTTPS sites exercise SameSite, not Chromium's separate loopback permission.
test.use({ ignoreHTTPSErrors: true, permissions: ["local-network-access"] });

for (const [port, prefix] of [[4022, "/widget"], [4023, "/support/chat"]] as const) {
  test(`HTTPS cross-site authenticated connect and reconnect on ${port}${prefix}`, async ({ page, request, context }) => {
    const origin = `https://127.0.0.1:${port}`;
    // Warm development code loading before minting the five-second first-binding JWT.
    expect((await request.get(origin + prefix + "/421")).ok()).toBe(true);
    const sockets: string[] = [];
    const errors: string[] = [];
    page.on("websocket", socket => sockets.push(socket.url()));
    page.on("pageerror", error => errors.push(error.message));
    await page.route("https://localhost:4023/parent", route => route.fulfill({
      contentType: "text/html", body: "<!doctype html><body></body>",
    }));
    let tokens = 0;
    await page.route("https://localhost:4023/token", async route => {
      tokens++;
      const issued = await request.get("http://127.0.0.1:4021/identity", {
        params: { widget_id: "421", user_id: `cookie-${port}-${crypto.randomUUID()}` },
      });
      await route.fulfill({ contentType: "application/json",
        headers: { "cache-control": "no-store" }, body: await issued.text() });
    });
    await page.goto("https://localhost:4023/parent");
    await page.evaluate(({ origin, prefix }) => {
      const script = document.createElement("script");
      script.src = origin + "/web_widget/assets/embed.js";
      script.dataset.widgetId = "421";
      script.dataset.widgetUrl = origin + prefix + "/421";
      script.dataset.tokenUrl = "/token";
      document.body.append(script);
    }, { origin, prefix });
    const widget = page.frameLocator("#zaq-widget");
    await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true");
    const input = widget.getByRole("textbox", { name: "Message", exact: true });
    await input.fill("instant");
    await input.press("Enter");
    await expect(widget.getByText("Immediate answer", { exact: true })).toBeVisible();
    await widget.locator("body").evaluate(() => {
      (window as any).liveSocket.disconnect();
      (window as any).liveSocket.connect();
    });
    await expect.poll(() => sockets.length).toBeGreaterThanOrEqual(2);
    await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true");
    expect(tokens).toBe(1);
    expect(sockets.every(url => url.startsWith(`wss://127.0.0.1:${port}${prefix}/421/live/websocket`))).toBe(true);
    expect(sockets.every(url => !new URL(url).searchParams.has("identity_token"))).toBe(true);
    const cookies = (await context.cookies()).filter(cookie => cookie.name === "_web_widget_session");
    expect(cookies).toEqual(expect.arrayContaining([expect.objectContaining({
      path: `${prefix}/421`, sameSite: "None", secure: true, httpOnly: true,
    })]));
    expect(errors).toEqual([]);
  });
}

test("independent policies coexist with an unchanged BO session", async ({ page, context }) => {
  const origin = "https://127.0.0.1:4023";
  await page.goto(origin + "/bo-session");
  const before = (await context.cookies()).find(cookie => cookie.name === "_host");
  for (const policy of ["none", "lax", "strict"]) {
    await page.goto(origin + "/widget/cookie-" + policy);
    await expect(page.locator("#widget-context")).toBeAttached();
    await expect.poll(() => page.evaluate(() => (window as any).liveSocket.isConnected())).toBe(true);
  }
  const cookies = await context.cookies();
  for (const [id, sameSite] of [["none", "None"], ["lax", "Lax"], ["strict", "Strict"]]) {
    expect(cookies).toEqual(expect.arrayContaining([expect.objectContaining({
      name: "_web_widget_session", path: "/widget/cookie-" + id, sameSite,
    })]));
  }
  await page.goto(origin + "/bo-session");
  await expect(page.locator("body")).toHaveText("admin");
  expect((await context.cookies()).find(cookie => cookie.name === "_host")).toEqual(before);
});

test("Lax and Strict cannot authorize a cross-site iframe transport", async ({ page }) => {
  await page.route("https://localhost:4023/parent", route => route.fulfill({
    contentType: "text/html", body: "<!doctype html><body></body>",
  }));
  await page.goto("https://localhost:4023/parent");
  for (const id of ["lax", "strict"]) {
    const rejected = page.waitForResponse(response =>
      response.url().includes(`/widget/cookie-${id}/live/longpoll`) && response.request().method() === "GET");
    await page.evaluate(id => {
      const iframe = document.createElement("iframe");
      iframe.id = id;
      iframe.src = `https://127.0.0.1:4023/widget/cookie-${id}`;
      document.body.append(iframe);
    }, id);
    // Phoenix long polling encodes its transport status in an HTTP 200 JSON body.
    expect(await (await rejected).json()).toMatchObject({ status: 403 });
    expect(await page.frameLocator(`#${id}`).locator("body").evaluate(() =>
      (window as any).liveSocket.isConnected())).toBe(false);
  }
});

test("None does not bypass browser third-party-cookie blocking", async ({ page, context, browserName }) => {
  test.skip(browserName !== "chromium", "Explicit cookie controls use Chromium CDP.");
  const cdp = await context.newCDPSession(page);
  await cdp.send("Network.enable");
  await cdp.send("Network.setCookieControls", {
    enableThirdPartyCookieRestriction: true,
    disableThirdPartyCookieMetadata: true,
    disableThirdPartyCookieHeuristics: true,
  });
  await page.route("https://localhost:4023/parent", route => route.fulfill({
    contentType: "text/html", body: "<!doctype html><body></body>",
  }));
  await page.goto("https://localhost:4023/parent");
  const rejected = page.waitForResponse(response =>
    response.url().includes("/widget/cookie-none/live/longpoll") && response.request().method() === "GET");
  await page.evaluate(() => {
    const iframe = document.createElement("iframe");
    iframe.id = "blocked-widget";
    iframe.src = "https://127.0.0.1:4023/widget/cookie-none";
    document.body.append(iframe);
  });
  expect(await (await rejected).json()).toMatchObject({ status: 403 });
  expect(await page.frameLocator("#blocked-widget").locator("body").evaluate(() =>
    (window as any).liveSocket.isConnected())).toBe(false);
});
