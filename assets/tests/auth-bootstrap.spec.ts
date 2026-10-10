import { expect, test, type Page, type Route } from "@playwright/test";

async function installTokenWidget(page: Page, navigate = true) {
  if (navigate) await page.goto("/widget/missing");
  await page.evaluate(async () => {
    const script = document.createElement("script");
    script.src = "http://127.0.0.1:4020/web_widget/assets/embed.js";
    script.setAttribute("data-widget-id", "420");
    script.setAttribute("data-token-url", "/api/widget-token");
    await new Promise<void>((resolve, reject) => {
      script.onload = () => resolve();
      script.onerror = () => reject(new Error("Embed did not load."));
      document.body.append(script);
    });
  });
}

test("token URL bootstraps in the fragment and renews without remounting", async ({ page, request }) => {
  let tokens = 0;
  let failRenewal = false;
  await page.route("**/api/widget-token", async route => {
    tokens++;
    if (failRenewal) return route.fulfill({ status: 503, body: "unavailable" });
    const issued = await request.get("http://127.0.0.1:4021/identity");
    const { identity_token } = await issued.json();
    await route.fulfill({
      status: 200,
      headers: { "content-type": "application/json", "cache-control": "no-store" },
      body: JSON.stringify({ identity_token }),
    });
  });

  await page.goto("/widget/missing");
  await page.evaluate(async () => {
    (window as any).publicReadyCount = 0;
    window.addEventListener("message", event => {
      if (event.data?.type === "zaq.widget.ready") (window as any).publicReadyCount++;
    });
    const script = document.createElement("script");
    script.src = "http://127.0.0.1:4020/web_widget/assets/embed.js";
    script.setAttribute("data-widget-id", "420");
    script.setAttribute("data-token-url", "/api/widget-token");
    await new Promise<void>((resolve, reject) => {
      script.onload = () => resolve();
      script.onerror = () => reject(new Error("Embed did not load."));
      document.body.append(script);
    });
  });

  const widget = page.frameLocator("#zaq-widget");
  await expect(widget.locator(".zaq-widget")).toBeVisible();
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true");
  await expect.poll(() => widget.locator("body").evaluate(() => location.hash)).toBe("");
  expect(tokens).toBe(1);
  const readyBeforeRenewal = await page.evaluate(() => (window as any).publicReadyCount);
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  await input.fill("Unsent draft");
  await input.evaluate(element => { (window as any).draftElement = element; });

  await page.evaluate(() => window.zaq.widget.connect());
  await expect.poll(() => tokens).toBe(2);
  await expect(input).toHaveValue("Unsent draft");
  expect(await input.evaluate(element => element === (window as any).draftElement)).toBe(true);
  expect(await page.evaluate(() => (window as any).publicReadyCount)).toBe(readyBeforeRenewal);

  failRenewal = true;
  await expect(page.evaluate(() => window.zaq.widget.connect())).rejects.toThrow("Widget token endpoint failed.");
  expect(tokens).toBe(3);
  await input.fill("instant");
  await input.press("Enter");
  await expect(widget.getByText("Immediate answer", { exact: true })).toBeVisible();
  await widget.locator("body").evaluate(() => {
    (window as any).liveSocket.disconnect();
    (window as any).liveSocket.connect();
  });
  await expect(widget.locator(".zaq-widget")).toBeVisible();
  expect(tokens).toBe(3);
});

test("identity JWT stays out of the LiveView WebSocket URL", async ({ page, request }) => {
  const websocketUrls: string[] = [];
  page.on("websocket", socket => websocketUrls.push(socket.url()));
  await page.route("**/api/widget-token", async route => {
    const issued = await request.get("http://127.0.0.1:4021/identity", {
      params: { user_id: `transport-${crypto.randomUUID()}` },
    });
    const { identity_token } = await issued.json();
    await route.fulfill({
      status: 200,
      headers: { "content-type": "application/json", "cache-control": "no-store" },
      body: JSON.stringify({ identity_token }),
    });
  });
  await installTokenWidget(page);
  await expect(page.frameLocator("#zaq-widget").locator("#widget-context")).toHaveAttribute("data-authorized", "true");
  await expect.poll(() => websocketUrls.length).toBeGreaterThan(0);
  for (const url of websocketUrls) {
    expect(new URL(url).searchParams.has("identity_token")).toBe(false);
  }
});

test("revocation during a network disconnect remains terminal on reconnect", async ({ page, request }) => {
  const user = `offline-revoked-${crypto.randomUUID()}`;
  let tokens = 0;
  await page.route("**/api/widget-token", async route => {
    tokens++;
    const issued = await request.get("http://127.0.0.1:4021/identity", { params: { user_id: user } });
    const { identity_token } = await issued.json();
    await route.fulfill({
      status: 200,
      headers: { "content-type": "application/json", "cache-control": "no-store" },
      body: JSON.stringify({ identity_token }),
    });
  });
  await installTokenWidget(page);
  const widget = page.frameLocator("#zaq-widget");
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true");
  expect(tokens).toBe(1);
  await widget.locator("body").evaluate(() => (window as any).liveSocket.disconnect());
  const { proof } = await (await request.get("http://127.0.0.1:4021/control-proof", { params: { user_id: user } })).json();
  const revoked = await request.post("http://127.0.0.1:4020/widget-api/420/disconnect", {
    headers: { Authorization: `Bearer ${proof}` }, data: { user_id: user },
  });
  expect(revoked.status()).toBe(200);
  await widget.locator("body").evaluate(() => (window as any).liveSocket.connect());
  await expect(widget.locator("#widget-backend-revoked")).toHaveText("Refresh the page to reconnect.");
  expect(tokens).toBe(1);
});

test("backend disconnect is scoped and a retried proof preserves a fresh session", async ({ page, context, request }) => {
  const user = `revoked-${crypto.randomUUID()}`;
  const unrelatedUser = `unrelated-${crypto.randomUUID()}`;
  let tokens = 0;
  let browserToken = "";
  await page.route("**/api/widget-token", async route => {
    tokens++;
    const issued = await request.get("http://127.0.0.1:4021/identity", { params: { user_id: user } });
    const { identity_token } = await issued.json();
    browserToken = identity_token;
    await route.fulfill({
      status: 200,
      headers: { "content-type": "application/json", "cache-control": "no-store" },
      body: JSON.stringify({ identity_token }),
    });
  });

  await page.goto("/widget/missing");
  await page.evaluate(async () => {
    const script = document.createElement("script");
    script.src = "http://127.0.0.1:4020/web_widget/assets/embed.js";
    script.setAttribute("data-widget-id", "420");
    script.setAttribute("data-token-url", "/api/widget-token");
    await new Promise<void>((resolve, reject) => {
      script.onload = () => resolve();
      script.onerror = () => reject(new Error("Embed did not load."));
      document.body.append(script);
    });
  });
  const widget = page.frameLocator("#zaq-widget");
  await expect(widget.locator(".zaq-widget")).toBeVisible();
  expect(tokens).toBe(1);

  const other = await context.newPage();
  await other.route("**/api/widget-token", async route => {
    tokens++;
    const issued = await request.get("http://127.0.0.1:4021/identity", { params: { user_id: user } });
    const { identity_token } = await issued.json();
    await route.fulfill({
      status: 200,
      headers: { "content-type": "application/json", "cache-control": "no-store" },
      body: JSON.stringify({ identity_token }),
    });
  });
  await installTokenWidget(other);
  const otherWidget = other.frameLocator("#zaq-widget");
  await expect(otherWidget.locator(".zaq-widget")).toBeVisible();
  expect(tokens).toBe(2);

  const unrelated = await context.newPage();
  await unrelated.route("**/api/widget-token", async route => {
    tokens++;
    const issued = await request.get("http://127.0.0.1:4021/identity", { params: { user_id: unrelatedUser } });
    const { identity_token } = await issued.json();
    await route.fulfill({
      status: 200,
      headers: { "content-type": "application/json", "cache-control": "no-store" },
      body: JSON.stringify({ identity_token }),
    });
  });
  await installTokenWidget(unrelated);
  const unrelatedWidget = unrelated.frameLocator("#zaq-widget");
  await expect(unrelatedWidget.locator(".zaq-widget")).toBeVisible();
  expect(tokens).toBe(3);

  const { proof } = await (await request.get("http://127.0.0.1:4021/control-proof", { params: { user_id: user } })).json();
  const denied = await request.post("http://127.0.0.1:4020/widget-api/420/disconnect", {
    headers: { Authorization: `Bearer ${browserToken}` }, data: { user_id: user },
  });
  expect(denied.status()).toBe(401);
  const wrongTarget = await request.post("http://127.0.0.1:4020/widget-api/420/disconnect", {
    headers: { Authorization: `Bearer ${proof}` }, data: { user_id: unrelatedUser },
  });
  expect(wrongTarget.status()).toBe(401);
  await expect(widget.locator("#widget-backend-revoked")).toHaveCount(0);
  await expect(otherWidget.locator("#widget-backend-revoked")).toHaveCount(0);
  await expect(unrelatedWidget.locator("#widget-backend-revoked")).toHaveCount(0);
  const disconnect = () => request.post("http://127.0.0.1:4020/widget-api/420/disconnect", {
    headers: { Authorization: `Bearer ${proof}` }, data: { user_id: user },
  });
  const first = await disconnect();
  expect(first.status()).toBe(200);
  await expect(widget.locator("#widget-backend-revoked")).toHaveText("Refresh the page to reconnect.");
  await expect(otherWidget.locator("#widget-backend-revoked")).toHaveText("Refresh the page to reconnect.");
  await expect(unrelatedWidget.locator("#widget-backend-revoked")).toHaveCount(0);
  await unrelatedWidget.getByRole("textbox", { name: "Message", exact: true }).fill("instant");
  await unrelatedWidget.getByRole("textbox", { name: "Message", exact: true }).press("Enter");
  await expect(unrelatedWidget.getByText("Immediate answer", { exact: true })).toBeVisible();
  const cutoff = (await first.json()).cutoff;
  await expect.poll(() => Math.floor(Date.now() / 1000)).toBeGreaterThan(cutoff);
  await other.evaluate(() => window.zaq.widget.dispose());
  await other.evaluate(() => window.zaq.widget.mountAuthenticated("http://127.0.0.1:4020/widget/420"));
  await expect(otherWidget.locator(".zaq-widget")).toBeVisible();
  await otherWidget.getByRole("textbox", { name: "Message", exact: true }).fill("instant");
  await otherWidget.getByRole("textbox", { name: "Message", exact: true }).press("Enter");
  await expect(otherWidget.getByText("Immediate answer", { exact: true })).toBeVisible();
  const retry = await disconnect();
  expect(retry.status()).toBe(200);
  expect((await retry.json()).cutoff).toBe(cutoff);
  await other.waitForTimeout(300);
  await expect(otherWidget.locator("#widget-backend-revoked")).toHaveCount(0);
  await otherWidget.getByRole("textbox", { name: "Message", exact: true }).fill("instant");
  await otherWidget.getByRole("textbox", { name: "Message", exact: true }).press("Enter");
  await expect(otherWidget.getByText("Immediate answer", { exact: true })).toHaveCount(2);
  await expect(widget.locator("#widget-backend-revoked")).toHaveText("Refresh the page to reconnect.");
  await other.close();
  await unrelated.close();
});

test("renewal preserves streamed Markdown, draft, and styled container", async ({ page, request }) => {
  const user = `stream-${crypto.randomUUID()}`;
  let tokens = 0;
  await page.route("**/api/widget-token", async route => {
    tokens++;
    const issued = await request.get("http://127.0.0.1:4021/identity", { params: { user_id: user } });
    const { identity_token } = await issued.json();
    await route.fulfill({
      status: 200,
      headers: { "content-type": "application/json", "cache-control": "no-store" },
      body: JSON.stringify({ identity_token }),
    });
  });
  await page.route("**/brand.css", route => route.fulfill({
    contentType: "text/css", body: ":root { --zaq-widget-composer-background: #302640; }",
  }));

  await page.goto("/widget/missing");
  await page.evaluate(async () => {
    const container = document.createElement("div");
    container.id = "chat";
    container.style.height = "600px";
    document.body.append(container);
    const script = document.createElement("script");
    script.src = "http://127.0.0.1:4020/web_widget/assets/embed.js";
    script.setAttribute("data-widget-id", "420");
    script.setAttribute("data-token-url", "/api/widget-token");
    script.setAttribute("iframe-location-id", "#chat");
    script.setAttribute("stylesheet-url", "/brand.css");
    await new Promise<void>((resolve, reject) => {
      script.onload = () => resolve();
      script.onerror = () => reject(new Error("Embed did not load."));
      document.body.append(script);
    });
  });
  const widget = page.frameLocator("#chat > iframe");
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  await expect(input).toBeVisible();
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true");
  await expect.poll(() => widget.locator("body").evaluate(() => location.hash)).toBe("");
  await expect(widget.locator(".zaq-composer")).toHaveCSS("background-color", "rgb(48, 38, 64)");
  const frame = page.locator("#chat > iframe");
  await frame.evaluate(element => { (window as any).authenticatedFrame = element; });
  await input.fill("markdown renewal");
  await input.press("Enter");
  await expect(widget.getByText("markdown renewal", { exact: true })).toBeVisible();
  const answer = widget.locator(".zaq-answer-content");
  await expect(answer.locator("strong")).toHaveText("Partial");
  await widget.locator(".zaq-widget").evaluate(element => { (window as any).reactBeforeRenewal = element; });
  const messageCount = async () => {
    const response = await request.get("http://127.0.0.1:4021/request-count", {
      params: { user_id: user, content: "markdown renewal" },
    });
    return (await response.json()).count as number;
  };
  expect(await messageCount()).toBe(1);
  await input.fill("Keep this draft");
  await input.evaluate(element => { (window as any).composerBeforeRenewal = element; });
  await page.evaluate(() => window.zaq.widget.connect());
  await expect(answer.locator("strong")).toHaveText("Finished");
  await expect(answer.locator("h2")).toHaveText("Update");
  await expect(widget.locator('[data-role="assistant"]')).toHaveCount(1);
  await expect(answer).not.toContainText("Partial");
  await expect(input).toHaveValue("Keep this draft");
  expect(await input.evaluate(element => element === (window as any).composerBeforeRenewal)).toBe(true);
  expect(await widget.locator(".zaq-widget").evaluate(element => element === (window as any).reactBeforeRenewal)).toBe(true);
  expect(await frame.evaluate(element => element === (window as any).authenticatedFrame)).toBe(true);
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true");
  expect(tokens).toBe(2);
  await frame.evaluate(element => {
    element.addEventListener("zaq:ready", () => { (window as any).reconnectedReady = true; }, { once: true });
  });
  await widget.locator("body").evaluate(() => {
    (window as any).liveSocket.disconnect();
    (window as any).liveSocket.connect();
  });
  await expect.poll(() => page.evaluate(() => (window as any).reconnectedReady === true)).toBe(true);
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true");
  expect(await messageCount()).toBe(1);
  expect(tokens).toBe(2);
  await input.fill("instant");
  await input.press("Enter");
  await expect(widget.getByText("Immediate answer", { exact: true })).toBeVisible();
  expect(await messageCount()).toBe(1);
});

for (const responsePhase of ["completed", "running"] as const) {
  test(`network reconnect restores ${responsePhase} stream history without resubmitting`, async ({ page, request }) => {
    const user = `network-${crypto.randomUUID()}`;
    let tokens = 0;
    await page.route("**/api/widget-token", async route => {
      tokens++;
      const issued = await request.get("http://127.0.0.1:4021/identity", { params: { user_id: user } });
      const { identity_token } = await issued.json();
      await route.fulfill({
        status: 200,
        headers: { "content-type": "application/json", "cache-control": "no-store" },
        body: JSON.stringify({ identity_token }),
      });
    });
    await installTokenWidget(page);
    const frame = page.locator("#zaq-widget");
    const widget = page.frameLocator("#zaq-widget");
    const input = widget.getByRole("textbox", { name: "Message", exact: true });
    await expect(input).toBeVisible();
    await frame.evaluate(element => {
      (window as any).reconnectReadyCount = 0;
      element.addEventListener("zaq:conversation", (event: any) => {
        (window as any).activeConversation = event.detail.conversation_id;
      });
      element.addEventListener("zaq:ready", () => { (window as any).reconnectReadyCount++; });
    });
    await input.fill("held stream");
    await input.press("Enter");
    await expect(widget.locator(".zaq-answer-content strong")).toHaveText("Partial");
    await expect.poll(() => page.evaluate(() => (window as any).activeConversation)).toBe("conversation-1");
    const submitted = async () => {
      const response = await request.get("http://127.0.0.1:4021/request-count", {
        params: { user_id: user, content: "held stream" },
      });
      return (await response.json()).count as number;
    };
    const status = async () => {
      const response = await request.get(`http://127.0.0.1:4021/held-stream/${user}`);
      return (await response.json()).status as string;
    };
    const complete = () => request.post(`http://127.0.0.1:4021/held-stream/${user}/complete`);
    expect(await submitted()).toBe(1);
    await widget.locator("body").evaluate(() => (window as any).liveSocket.disconnect());
    await expect(widget.getByRole("button", { name: "Send message", exact: true })).toBeDisabled();
    await expect(widget.locator(".zaq-connection")).toHaveText("Reconnecting to recover the response…");
    await expect(widget.locator(".zaq-answer-content strong")).toHaveText("Partial");
    await expect(widget.locator(".zaq-working")).toBeHidden();
    if (responsePhase === "completed") {
      expect((await complete()).status()).toBe(204);
      await expect.poll(status).toBe("finished");
    } else {
      expect(await status()).toBe("running");
    }
    await widget.locator("body").evaluate(() => (window as any).liveSocket.connect());
    await expect.poll(() => page.evaluate(() => (window as any).reconnectReadyCount)).toBe(1);
    await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true");
    await expect(widget.locator(".zaq-answer-content strong")).toHaveText(responsePhase === "completed" ? "Finished" : "Partial");
    await expect(widget.locator(".zaq-connection")).toHaveCount(0);
    await expect(widget.getByText("held stream", { exact: true })).toHaveCount(1);
    await expect(widget.locator('[data-role="assistant"]')).toHaveCount(1);
    expect(tokens).toBe(1);
    expect(await submitted()).toBe(1);
    if (responsePhase === "running") {
      expect((await complete()).status()).toBe(204);
      await expect.poll(status).toBe("finished");
      await expect(widget.locator(".zaq-answer-content strong")).toHaveText("Finished", { timeout: 10_000 });
      expect(await page.evaluate(() => (window as any).reconnectReadyCount)).toBe(1);
      await expect(widget.getByText("held stream", { exact: true })).toHaveCount(1);
      await expect(widget.locator('[data-role="assistant"]')).toHaveCount(1);
      expect(tokens).toBe(1);
      expect(await submitted()).toBe(1);
    }
  });
}

for (const answerTiming of ["during", "after"] as const) {
  test(`automatic renewal with five minutes remaining preserves the original answer ${answerTiming} renewal`, async ({ page, request }) => {
    test.setTimeout(45_000);
    const user = `early-renewal-${answerTiming}-${crypto.randomUUID()}`;
    const control = "http://127.0.0.1:4021";
    let tokenRequests = 0;
    let releaseReplacement!: () => void;
    const replacementGate = new Promise<void>(resolve => { releaseReplacement = resolve; });
    const credentials: Array<{ jti: string; exp: number }> = [];
    await page.route("**/api/widget-token", async route => {
      const attempt = ++tokenRequests;
      if (attempt > 1) await replacementGate;
      const issued = await request.get(`${control}/identity`, {
        params: { user_id: user, ...(attempt === 1 ? { ttl: "315" } : {}) },
      });
      const { identity_token } = await issued.json();
      credentials.push(JSON.parse(Buffer.from(identity_token.split(".")[1], "base64url").toString()));
      await route.fulfill({ headers: { "cache-control": "no-store" }, json: { identity_token } });
    });
    const session = async () => {
      const { sessions } = await (await request.get(`${control}/liveview-sessions/${user}`)).json();
      expect(sessions).toHaveLength(1);
      return sessions[0];
    };
    const submissions = async () => (await (await request.get(`${control}/request-count`, {
      params: { user_id: user, content: "held stream" },
    })).json()).count;
    try {
      await installTokenWidget(page);
      const iframe = page.locator("#zaq-widget");
      const widget = page.frameLocator("#zaq-widget");
      const auth = widget.locator("#widget-context");
      await expect(auth).toHaveAttribute("data-authorized", "true");
      await iframe.evaluate(element => {
        (window as any).earlyRenewalFrame = element;
        (window as any).authenticationRequired = [];
        element.addEventListener("zaq:authentication-required", (event: Event) => {
          (window as any).authenticationRequired.push((event as CustomEvent).detail);
        });
      });
      await widget.locator("body").evaluate(() => { (window as any).earlyRenewalDocument = document; });
      const initial = await session();
      expect(initial.expires_at - initial.server_time).toBeGreaterThan(300);
      expect(Number(await auth.getAttribute("data-auth-refresh-at"))).toBe(initial.expires_at - 300);
      const input = widget.getByRole("textbox", { name: "Message", exact: true });
      await input.fill("held stream");
      await input.press("Enter");
      await expect(widget.locator(".zaq-answer-content strong")).toHaveText("Partial");
      const original = await (await request.get(`${control}/held-stream/${user}`)).json();
      expect((await session()).active.request_id).toBe(original.request_id);
      expect(tokenRequests).toBe(1);

      // Real scheduled renewal: no manual connect, synthetic event, or clock jump.
      await expect.poll(() => tokenRequests, { timeout: 20_000 }).toBe(2);
      const pending = await session();
      expect(pending.expires_at - pending.server_time).toBeGreaterThanOrEqual(295);
      expect(pending.expires_at - pending.server_time).toBeLessThanOrEqual(300);
      expect(pending.credential_id).toBe(credentials[0].jti);
      expect(pending.binding_authorized).toBe(true);
      expect(pending.authentication_pending).toBe(false);
      expect(pending.response_subscribed).toBe(true);
      expect(pending.pid).toBe(initial.pid);

      if (answerTiming === "during") {
        expect((await request.post(`${control}/held-stream/${user}/complete`)).status()).toBe(204);
        await expect(widget.locator(".zaq-answer-content strong")).toHaveText("Finished");
        expect(credentials).toHaveLength(1);
        expect((await session()).credential_id).toBe(initial.credential_id);
        await input.fill("Draft during renewal");
        await expect(widget.getByRole("button", { name: "Send message", exact: true })).toBeEnabled();
      }

      releaseReplacement();
      await expect.poll(async () => (await session()).credential_id).not.toBe(initial.credential_id);
      const renewed = await session();
      expect(credentials).toHaveLength(2);
      expect(renewed.credential_id).toBe(credentials[1].jti);
      expect(renewed.server_time).toBeLessThan(initial.expires_at);
      expect(renewed.pid).toBe(initial.pid);
      expect(renewed.page_id).toBe(initial.page_id);
      expect(renewed.conversation_id).toBe(original.conversation_id);
      expect(renewed.topic).toBe(original.topic);
      expect(renewed.binding_authorized).toBe(true);
      expect(renewed.authentication_pending).toBe(false);
      expect(renewed.response_subscribed).toBe(true);
      if (answerTiming === "after") {
        expect(renewed.active.request_id).toBe(original.request_id);
        expect((await request.post(`${control}/held-stream/${user}/complete`)).status()).toBe(204);
      }
      await expect(widget.locator(".zaq-answer-content strong")).toHaveText("Finished");
      await expect(widget.locator('[data-role="user"]')).toHaveCount(1);
      await expect(widget.locator('[data-role="assistant"]')).toHaveCount(1);
      expect(await submissions()).toBe(1);
      expect(tokenRequests).toBe(2);
      expect(await page.evaluate(() => (window as any).authenticationRequired)).toEqual([]);
      expect(await iframe.evaluate(element => element === (window as any).earlyRenewalFrame)).toBe(true);
      expect(await widget.locator("body").evaluate(() => document === (window as any).earlyRenewalDocument)).toBe(true);
      await input.fill("instant");
      await expect(widget.getByRole("button", { name: "Send message", exact: true })).toBeEnabled();
      await input.press("Enter");
      await expect(widget.getByText("Immediate answer", { exact: true })).toBeVisible();
    } finally {
      releaseReplacement();
    }
  });
}

test("actual JWT expiry during a held response restores the final answer after authentication recovery", async ({ page, request }, testInfo) => {
  test.setTimeout(45_000);
  const user = `expiry-stream-${crypto.randomUUID()}`;
  const control = "http://127.0.0.1:4021";
  let allowReplacement = false;
  const credentials: Array<{ jti: string; exp: number }> = [];
  await page.route("**/api/widget-token", async route => {
    if (credentials.length && !allowReplacement) {
      await route.fulfill({ status: 503, body: "Temporarily unavailable" });
      return;
    }
    const issued = await request.get(`${control}/identity`, {
      params: { user_id: user, ...(credentials.length ? {} : { ttl: "8" }) },
    });
    const { identity_token } = await issued.json();
    credentials.push(JSON.parse(Buffer.from(identity_token.split(".")[1], "base64url").toString()));
    await route.fulfill({
      status: 200,
      headers: { "content-type": "application/json", "cache-control": "no-store" },
      body: JSON.stringify({ identity_token }),
    });
  });
  const session = async () => {
    const response = await request.get(`${control}/liveview-sessions/${user}`);
    const { sessions } = await response.json();
    expect(sessions).toHaveLength(1);
    return sessions[0];
  };
  const stream = async () => (await request.get(`${control}/held-stream/${user}`)).json();
  const submissions = async () => (await (await request.get(`${control}/request-count`, {
    params: { user_id: user, content: "held stream" },
  })).json()).count;
  const evidence: Record<string, unknown> = {};
  try {
    await installTokenWidget(page);
    const iframe = page.locator("#zaq-widget");
    const widget = page.frameLocator("#zaq-widget");
    const auth = widget.locator("#widget-context");
    await expect(auth).toHaveAttribute("data-authorized", "true");
    await iframe.evaluate(element => { (window as any).expiryTestFrame = element; });
    await widget.locator("body").evaluate(() => { (window as any).expiryTestDocument = document; });
    const initial = await session();
    evidence.initial = initial;
    expect(initial.credential_id).toBe(credentials[0].jti);
    expect(initial.binding_authorized).toBe(true);
    expect(initial.binding_page_id).toBe(initial.page_id);
    expect(initial.response_subscribed).toBe(true);
    expect(initial.revocation_subscribed).toBe(true);
    const input = widget.getByRole("textbox", { name: "Message", exact: true });
    await input.fill("held stream");
    await input.press("Enter");
    await expect(widget.locator(".zaq-answer-content strong")).toHaveText("Partial");
    const original = await stream();
    evidence.original = original;
    expect(original.status).toBe("running");
    expect(original.topic).toBe(initial.topic);
    expect((await session()).active.request_id).toBe(original.request_id);
    expect(await submissions()).toBe(1);

    // Only the real WidgetLive expiry path sets authentication_pending here.
    // No socket disconnect, renewal invocation, or synthetic expiry event is used.
    await expect.poll(async () => (await session()).authentication_pending, { timeout: 15_000 }).toBe(true);
    const expired = await session();
    evidence.expired = expired;
    expect(expired.server_time).toBeGreaterThanOrEqual(credentials[0].exp);
    expect(expired.credential_id).toBe(credentials[0].jti);
    expect(expired.binding_authorized).toBe(false);
    expect(credentials).toHaveLength(1);
    await expect(auth).toHaveAttribute("data-authorized", "false");
    // A real host event while unauthorized must not mutate state or render.
    expect((await request.post(`${control}/held-stream/${user}/probe`)).status()).toBe(204);
    expect((await session()).state).toBe(expired.state);
    await expect(widget.getByText("UNAUTHORIZED EXPIRY PROBE", { exact: true })).toHaveCount(0);
    expect((await stream()).status).toBe("running");

    allowReplacement = true;
    await expect.poll(async () => (await session()).credential_id, { timeout: 10_000 }).not.toBe(initial.credential_id);
    await expect(auth).toHaveAttribute("data-authorized", "true");
    const recovered = await session();
    evidence.recovered = recovered;
    expect(credentials).toHaveLength(2);
    expect(recovered.credential_id).toBe(credentials[1].jti);
    expect(recovered.server_time).toBeGreaterThanOrEqual(credentials[0].exp);
    expect(recovered.binding_authorized).toBe(true);
    expect(recovered.authentication_pending).toBe(false);
    expect(recovered.page_id).toBe(initial.page_id);
    expect(recovered.binding_page_id).toBe(initial.page_id);
    expect(recovered.pid).toBe(initial.pid);
    expect(recovered.topic).toBe(original.topic);
    expect(recovered.response_subscribed).toBe(true);
    expect(recovered.revocation_subscribed).toBe(true);
    expect(recovered.conversation_id).toBe(original.conversation_id);
    expect(await iframe.evaluate(element => element === (window as any).expiryTestFrame)).toBe(true);
    expect(await widget.locator("body").evaluate(() => document === (window as any).expiryTestDocument)).toBe(true);
    expect(await submissions()).toBe(1);
    await expect(widget.locator(".zaq-answer-content strong")).toHaveText("Partial");

    // The final is published to the ORIGINAL request's delivery context only
    // after JWT B has been verified and bound. No action follows this release.
    expect((await stream()).status).toBe("running");
    expect((await request.post(`${control}/held-stream/${user}/complete`)).status()).toBe(204);
    expect(await stream()).toEqual({ ...original, status: "finished" });
    await expect.soft(widget.locator(".zaq-answer-content strong")).toHaveText("Finished", { timeout: 10_000 });
    evidence.afterFinal = await session();
    expect(await submissions()).toBe(1);
    expect(credentials).toHaveLength(2);
    await expect(widget.getByText("held stream", { exact: true })).toHaveCount(1);
    await expect(widget.locator('[data-role="user"]')).toHaveCount(1);
    await expect(widget.locator('[data-role="assistant"]')).toHaveCount(1);
    expect((await session()).conversation_id).toBe(original.conversation_id);
  } finally {
    await testInfo.attach("expiry-response-lifecycle", {
      body: JSON.stringify(evidence, null, 2), contentType: "application/json",
    });
  }
});

test("WebSocket reconnect replaces the LiveView process and preserves host message delivery", async ({ page, request }) => {
  const clockStart = Date.now();
  await page.clock.install({ time: clockStart });
  const user = `socket-${crypto.randomUUID()}`;
  await page.route("**/api/widget-token", async route => {
    const issued = await request.get("http://127.0.0.1:4021/identity", { params: { user_id: user } });
    const { identity_token } = await issued.json();
    await route.fulfill({
      status: 200,
      headers: { "content-type": "application/json", "cache-control": "no-store" },
      body: JSON.stringify({ identity_token }),
    });
  });
  await installTokenWidget(page);

  const widget = page.frameLocator("#zaq-widget");
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true");
  const sessions = async () => {
    const response = await request.get(`http://127.0.0.1:4021/liveview-sessions/${user}`);
    expect(response.ok()).toBe(true);
    return (await response.json()).sessions as Array<{ pid: string; topic: string; conversation_id: string | null }>;
  };
  const hostRequests = async () => {
    const response = await request.get(`http://127.0.0.1:4021/requests/${user}`);
    expect(response.ok()).toBe(true);
    return await response.json() as Array<{ type: string; content?: string; conversation_id: string | null }>;
  };
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  const firstMessage = `reconnect before ${user}`;
  const secondMessage = `reconnect after ${user}`;
  await input.fill(firstMessage);
  await input.press("Enter");
  await expect(widget.getByText(`Answer to ${firstMessage}`, { exact: true })).toBeVisible();
  await expect.poll(sessions).toHaveLength(1);
  const [before] = await sessions();
  expect(before.conversation_id).toMatch(/^e2e-/);
  expect((await hostRequests()).filter(r => r.content)).toEqual([
    expect.objectContaining({ content: firstMessage, conversation_id: null }),
  ]);

  const banner = widget.locator(".zaq-connection");
  const send = widget.getByRole("button", { name: "Send message", exact: true });
  const waitForReplacement = async (previousPid: string) => {
    await expect.poll(async () => {
      // The server/network uses real time while this test pauses browser timers.
      // Keep advancing those timers until both mount and presentation complete.
      await page.clock.runFor(100);
      const active = await sessions();
      return {
        count: active.length,
        replaced: active.length === 1 && active[0].pid !== previousPid,
        authorized: await widget.locator("#widget-context").getAttribute("data-authorized"),
        reconnecting: await widget.locator(".zaq-widget").getAttribute("data-reconnecting"),
      };
    }).toEqual({ count: 1, replaced: true, authorized: "true", reconnecting: "false" });
    const [replacement] = await sessions();
    expect(replacement.pid).not.toBe(previousPid);
    expect(replacement.topic).toBe(before.topic);
    expect(replacement.conversation_id).toBe(before.conversation_id);
    return replacement;
  };
  await input.fill(secondMessage);
  await expect(send).toBeEnabled();
  // Inspector pauses must not consume the banner's grace period.
  await page.clock.pauseAt(clockStart + 60 * 60 * 1000);
  await widget.locator("body").evaluate(() => (window as any).liveSocket.disconnect());
  await page.clock.runFor(300);
  await expect(send).toBeDisabled();
  await expect(banner).toHaveCount(0);
  await expect.poll(sessions).toEqual([]);
  await page.clock.runFor(2000);
  await expect(banner).toHaveText("Connection lost. Reconnecting…");
  await expect(widget.getByText(`Answer to ${firstMessage}`, { exact: true })).toBeVisible();
  await input.press("Enter");
  await expect(input).toHaveValue(secondMessage);
  expect((await hostRequests()).filter(r => r.content)).toHaveLength(1);

  await expect(banner.getByRole("button")).toHaveCount(0);
  await page.clock.runFor(13000);
  await expect(banner).toHaveText("Connection lost. Reconnecting…");
  await expect(banner.getByRole("button")).toHaveCount(0);
  await widget.locator("body").evaluate(() => (window as any).liveSocket.connect());
  await waitForReplacement(before.pid);
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true");
  await expect.poll(sessions).toHaveLength(1);
  const [after] = await sessions();
  expect(after.pid).not.toBe(before.pid);
  expect(after.topic).toBe(before.topic);
  expect(after.conversation_id).toBe(before.conversation_id);
  await expect(banner).toHaveCount(0);
  await expect(input).toHaveValue(secondMessage);
  await expect(send).toBeEnabled();
  await expect(widget.getByText(firstMessage, { exact: true })).toBeVisible();
  await expect(widget.getByText(`Answer to ${firstMessage}`, { exact: true })).toBeVisible();

  const restored = await hostRequests();
  expect(restored).toEqual(expect.arrayContaining([
    expect.objectContaining({ type: "conversation_init", conversation_id: before.conversation_id }),
    expect.objectContaining({ type: "conversation_history", conversation_id: before.conversation_id }),
  ]));
  expect(restored.filter(r => r.content)).toHaveLength(1);

  await input.press("Enter");
  await expect.poll(async () => (await hostRequests()).filter(r => r.content)).toEqual([
    expect.objectContaining({ content: firstMessage, conversation_id: null }),
    expect.objectContaining({ content: secondMessage, conversation_id: before.conversation_id }),
  ]);
  await expect(widget.getByText(`Answer to ${secondMessage}`, { exact: true })).toBeVisible();
  for (const message of [firstMessage, secondMessage]) {
    await expect(widget.getByText(message, { exact: true })).toHaveCount(1);
    await expect(widget.getByText(`Answer to ${message}`, { exact: true })).toHaveCount(1);
  }
  await expect(widget.locator('[data-role="assistant"]')).toHaveCount(2);
  expect((await hostRequests()).filter(r => r.content)).toHaveLength(2);
  expect((await sessions())[0].conversation_id).toBe(before.conversation_id);
  await page.clock.runFor(2000);
  await expect(banner).toHaveCount(0);

  await input.fill("Draft after a brief interruption");
  await widget.locator("body").evaluate(() => (window as any).liveSocket.disconnect());
  await expect.poll(sessions).toEqual([]);
  await widget.locator("body").evaluate(() => (window as any).liveSocket.connect());
  await waitForReplacement(after.pid);
  await expect(widget.locator(".zaq-widget")).toHaveAttribute("data-reconnecting", "false");
  await expect(banner).toHaveCount(0);
  await expect(input).toHaveValue("Draft after a brief interruption");
  expect((await hostRequests()).filter(r => r.content)).toHaveLength(2);
});

test("connection status follows French and Arabic presentation settings", async ({ page, request }) => {
  const user = `connection-locale-${crypto.randomUUID()}`;
  await page.route("**/api/widget-token", async route => {
    const issued = await request.get("http://127.0.0.1:4021/identity", { params: { user_id: user } });
    await route.fulfill({ headers: { "cache-control": "no-store" }, json: await issued.json() });
  });
  await installTokenWidget(page);
  const widget = page.frameLocator("#zaq-widget");
  await expect(widget.getByRole("textbox", { name: "Message", exact: true })).toBeVisible();

  for (const [language, direction, reconnecting] of [
    ["fr", "ltr", "Connexion perdue. Reconnexion en cours…"],
    ["ar", "rtl", "انقطع الاتصال. جارٍ إعادة الاتصال…"],
  ] as const) {
    await page.evaluate(language => window.zaq.widget.updateSettings({ language }), language);
    await expect(widget.locator("html")).toHaveAttribute("dir", direction);
    await widget.locator("body").evaluate(() => (window as any).liveSocket.disconnect());
    await expect(widget.locator(".zaq-connection")).toHaveText(reconnecting);
    await widget.locator("body").evaluate(() => (window as any).liveSocket.connect());
    await expect(widget.locator(".zaq-connection")).toHaveCount(0);
  }
});

test("delayed and lost renewal acknowledgements leave the active chat usable", async ({ page, request }) => {
  const user = `lost-ack-${crypto.randomUUID()}`;
  let tokens = 0;
  await page.route("**/api/widget-token", async route => {
    tokens++;
    const issued = await request.get("http://127.0.0.1:4021/identity", { params: { user_id: user } });
    const { identity_token } = await issued.json();
    await route.fulfill({
      status: 200,
      headers: { "content-type": "application/json", "cache-control": "no-store" },
      body: JSON.stringify({ identity_token }),
    });
  });
  await page.goto("/widget/missing");
  await page.evaluate(async () => {
    (window as any).ackDropped = false;
    (window as any).ackDelayed = false;
    (window as any).ackMode = "normal";
    window.addEventListener("message", event => {
      const mode = (window as any).ackMode;
      if (mode === "normal" || event.data?.type !== "zaq.widget.result" ||
          typeof event.data.credential_id !== "string") return;
      event.stopImmediatePropagation();
      (window as any).ackMode = "normal";
      if (mode === "delay") {
        (window as any).ackDelayed = true;
        const { data, origin, source } = event;
        window.setTimeout(() => {
          try {
            window.dispatchEvent(new MessageEvent("message", { data, origin, source }));
          } catch {
            window.dispatchEvent(event);
          }
        }, 500);
      } else {
        (window as any).ackDropped = true;
      }
    }, true);
    const script = document.createElement("script");
    script.src = "http://127.0.0.1:4020/web_widget/assets/embed.js";
    script.setAttribute("data-widget-id", "420");
    script.setAttribute("data-token-url", "/api/widget-token");
    await new Promise<void>((resolve, reject) => {
      script.onload = () => resolve();
      script.onerror = () => reject(new Error("Embed did not load."));
      document.body.append(script);
    });
  });
  const widget = page.frameLocator("#zaq-widget");
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  await expect(input).toBeVisible();
  await input.fill("Draft during delayed ack");
  await page.evaluate(() => {
    (window as any).ackMode = "delay";
    (window as any).delayedResult = window.zaq.widget.connect()
      .then(() => "accepted", (error: Error) => error.message);
  });
  await expect.poll(() => page.evaluate(() => (window as any).ackDelayed)).toBe(true);
  await expect.poll(() => page.evaluate(() => (window as any).delayedResult)).toBe("accepted");
  await expect(input).toHaveValue("Draft during delayed ack");
  await page.evaluate(() => {
    (window as any).ackMode = "drop";
    (window as any).renewalResult = window.zaq.widget.connect()
      .then(() => "accepted", (error: Error) => error.message);
  });
  await expect.poll(() => page.evaluate(() => (window as any).ackDropped)).toBe(true);
  await input.fill("instant");
  await input.press("Enter");
  await expect(widget.getByText("Immediate answer", { exact: true })).toBeVisible();
  expect(await page.evaluate(() => (window as any).renewalResult)).toBe("Widget request timed out.");
  expect(tokens).toBeGreaterThanOrEqual(2);
  await expect(widget.getByRole("textbox", { name: "Message", exact: true })).toBeVisible();
});

test("a JWT bound to one browser page cannot bootstrap another page", async ({ page, context, request }) => {
  const { identity_token } = await (await request.get("http://127.0.0.1:4021/identity", {
    params: { user_id: `replay-${crypto.randomUUID()}` },
  })).json();
  const tokenResponse = async (route: Route) => route.fulfill({
    status: 200,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
    body: JSON.stringify({ identity_token }),
  });
  await page.route("**/api/widget-token", tokenResponse);
  await installTokenWidget(page);
  const first = page.frameLocator("#zaq-widget");
  await expect(first.locator("#widget-context")).toHaveAttribute("data-authorized", "true");

  const other = await context.newPage();
  await other.route("**/api/widget-token", tokenResponse);
  await installTokenWidget(other);
  const replay = other.frameLocator("#zaq-widget");
  await expect(replay.locator("#widget-context")).toHaveAttribute("data-authorized", "false");
  await expect(replay.locator(".zaq-widget")).toHaveCount(0);
  await first.getByRole("textbox", { name: "Message", exact: true }).fill("instant");
  await first.getByRole("textbox", { name: "Message", exact: true }).press("Enter");
  await expect(first.getByText("Immediate answer", { exact: true })).toBeVisible();
  await other.close();
});

test("a stale first JWT is rejected and a freshly issued JWT restores the same iframe", async ({ page, request }) => {
  const user = `stale-${crypto.randomUUID()}`;
  let stale = true;
  let tokens = 0;
  await page.route("**/api/widget-token", async route => {
    tokens++;
    const issued = await request.get("http://127.0.0.1:4021/identity", {
      params: { user_id: user, ...(stale ? { stale: "true" } : {}) },
    });
    const { identity_token } = await issued.json();
    await route.fulfill({
      status: 200,
      headers: { "content-type": "application/json", "cache-control": "no-store" },
      body: JSON.stringify({ identity_token }),
    });
  });
  await installTokenWidget(page);
  const frame = page.locator("#zaq-widget");
  const widget = page.frameLocator("#zaq-widget");
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "false");
  await expect(widget.locator(".zaq-widget")).toHaveCount(0);
  await frame.evaluate(element => { (window as any).staleFrame = element; });
  stale = false;
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true", { timeout: 10_000 });
  expect(tokens).toBeGreaterThanOrEqual(2);
  expect(await frame.evaluate(element => element === (window as any).staleFrame)).toBe(true);
  await widget.getByRole("textbox", { name: "Message", exact: true }).fill("instant");
  await widget.getByRole("textbox", { name: "Message", exact: true }).press("Enter");
  await expect(widget.getByText("Immediate answer", { exact: true })).toBeVisible();
});

test("delayed iframe bootstrap replaces a stale first token without reloading the iframe", async ({ page, request }) => {
  const user = `delayed-${crypto.randomUUID()}`;
  await page.goto("/widget/missing");
  let tokens = 0;
  let releaseBootstrap!: () => void;
  const bootstrapGate = new Promise<void>(resolve => { releaseBootstrap = resolve; });
  let appRequested = false;
  await page.route("**/web_widget/assets/app.js", async route => {
    appRequested = true;
    await bootstrapGate;
    await route.continue();
  });
  await page.route("**/api/widget-token", async route => {
    tokens++;
    const issued = await request.get("http://127.0.0.1:4021/identity", { params: { user_id: user } });
    const { identity_token } = await issued.json();
    await route.fulfill({
      status: 200,
      headers: { "content-type": "application/json", "cache-control": "no-store" },
      body: JSON.stringify({ identity_token }),
    });
  });
  await installTokenWidget(page, false);
  await expect.poll(() => appRequested).toBe(true);
  const frame = page.locator("#zaq-widget");
  await frame.evaluate(element => { (window as any).delayedFrame = element; });
  expect(tokens).toBe(1);
  await page.waitForTimeout(5_200);
  releaseBootstrap();
  const widget = page.frameLocator("#zaq-widget");
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true", { timeout: 10_000 });
  await expect(widget.locator(".zaq-widget")).toBeVisible();
  expect(tokens).toBeGreaterThanOrEqual(2);
  expect(await frame.evaluate(element => element === (window as any).delayedFrame)).toBe(true);
});

test("a short credential renews automatically before expiry", async ({ page, request }) => {
  const user = `automatic-${crypto.randomUUID()}`;
  let tokens = 0;
  await page.route("**/api/widget-token", async route => {
    tokens++;
    const issued = await request.get("http://127.0.0.1:4021/identity", {
      params: { user_id: user, ...(tokens === 1 ? { short: "true" } : {}) },
    });
    const { identity_token } = await issued.json();
    await route.fulfill({
      status: 200,
      headers: { "content-type": "application/json", "cache-control": "no-store" },
      body: JSON.stringify({ identity_token }),
    });
  });
  await installTokenWidget(page);
  const widget = page.frameLocator("#zaq-widget");
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  await expect(input).toBeVisible();
  const initialCredential = await widget.locator("#widget-context").getAttribute("data-auth-credential-id");
  const initialExpiry = Number(await widget.locator("#widget-context").getAttribute("data-auth-expires-at"));
  const frame = page.locator("#zaq-widget");
  await frame.evaluate(element => { (window as any).automaticFrame = element; });
  await input.fill("Preserved while refreshing");
  await expect.poll(() => tokens, { timeout: 6000 }).toBe(2);
  await expect(widget.locator("#widget-context")).not.toHaveAttribute("data-auth-credential-id", initialCredential!);
  await expect.poll(() => Math.floor(Date.now() / 1000)).toBeGreaterThan(initialExpiry);
  await expect(input).toHaveValue("Preserved while refreshing");
  expect(await frame.evaluate(element => element === (window as any).automaticFrame)).toBe(true);
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true");
  await input.fill("instant");
  await input.press("Enter");
  await expect(widget.getByText("Immediate answer", { exact: true })).toBeVisible();
});

test("a full iframe reload fetches a new JWT for its new LiveView page", async ({ page, request }) => {
  const user = `reload-${crypto.randomUUID()}`;
  let tokens = 0;
  await page.route("**/api/widget-token", async route => {
    tokens++;
    const issued = await request.get("http://127.0.0.1:4021/identity", { params: { user_id: user } });
    const { identity_token } = await issued.json();
    await route.fulfill({
      status: 200,
      headers: { "content-type": "application/json", "cache-control": "no-store" },
      body: JSON.stringify({ identity_token }),
    });
  });
  await installTokenWidget(page);
  const frame = page.locator("#zaq-widget");
  const widget = page.frameLocator("#zaq-widget");
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true");
  const firstCredential = await widget.locator("#widget-context").getAttribute("data-auth-credential-id");
  expect(tokens).toBe(1);
  await frame.evaluate(element => {
    (window as any).reloadFrame = element;
    const target = new URL((element as HTMLIFrameElement).src);
    target.searchParams.set("reload", crypto.randomUUID());
    (element as HTMLIFrameElement).src = target.href;
  });
  await expect.poll(() => tokens).toBe(2);
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true");
  await expect(widget.locator("#widget-context")).not.toHaveAttribute("data-auth-credential-id", firstCredential!);
  expect(await frame.evaluate(element => element === (window as any).reloadFrame)).toBe(true);
  await expect(widget.locator(".zaq-widget")).toBeVisible();
});

test("renewal endpoint outage retries after expiry and recovers automatically in the same iframe", async ({ page, request }) => {
  const user = `outage-${crypto.randomUUID()}`;
  let attempts = 0;
  let available = false;
  await page.route("**/api/widget-token", async route => {
    attempts++;
    if (attempts > 1 && !available) return route.fulfill({ status: 503, body: "temporarily unavailable" });
    const issued = await request.get("http://127.0.0.1:4021/identity", {
      params: { user_id: user, ...(attempts === 1 ? { ttl: "8" } : {}) },
    });
    const { identity_token } = await issued.json();
    await route.fulfill({
      status: 200,
      headers: { "content-type": "application/json", "cache-control": "no-store" },
      body: JSON.stringify({ identity_token }),
    });
  });
  await installTokenWidget(page);
  const frame = page.locator("#zaq-widget");
  const widget = page.frameLocator("#zaq-widget");
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  await expect(input).toBeVisible();
  await frame.evaluate(element => { (window as any).outageFrame = element; });
  await expect.poll(() => attempts).toBeGreaterThanOrEqual(2);
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true");
  await input.fill("instant");
  await input.press("Enter");
  await expect(widget.getByText("Immediate answer", { exact: true })).toBeVisible();
  await input.fill("Draft through expiry");
  await expect.poll(() => attempts).toBeGreaterThanOrEqual(3);
  await expect(widget.getByRole("button", { name: "Send message", exact: true })).toBeDisabled({ timeout: 10_000 });
  await expect(input).toHaveValue("Draft through expiry");
  await expect(page.evaluate(() => window.zaq.widget.connect())).rejects.toThrow("Widget token endpoint failed.");
  const failedAttempts = attempts;
  available = true;
  await expect.poll(() => attempts, { timeout: 5_000 }).toBeGreaterThan(failedAttempts);
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true");
  await expect(widget.getByRole("button", { name: "Send message", exact: true })).toBeEnabled();
  await expect(input).toHaveValue("Draft through expiry");
  expect(await frame.evaluate(element => element === (window as any).outageFrame)).toBe(true);
  await expect(widget.getByText("Immediate answer", { exact: true })).toHaveCount(0);
  await input.fill("instant");
  await input.press("Enter");
  await expect(widget.getByText("Immediate answer", { exact: true })).toBeVisible();
  const submissions = await (await request.get("http://127.0.0.1:4021/request-count", {
    params: { user_id: user, content: "instant" },
  })).json();
  expect(submissions.count).toBe(2);
});

test("invalid JWT and token endpoint failures block bootstrap, then a valid endpoint recovers", async ({ page, request }) => {
  const { identity_token } = await (await request.get("http://127.0.0.1:4021/identity", {
    params: { user_id: `recovery-${crypto.randomUUID()}` },
  })).json();
  const parts = identity_token.split(".");
  parts[2] = (parts[2][0] === "A" ? "B" : "A") + parts[2].slice(1);
  const invalidToken = parts.join(".");
  let response: "http" | "json" | "missing" | "cache" | "invalid" | "valid" = "http";
  await page.route("**/api/widget-token", route => {
    if (response === "http") return route.fulfill({ status: 503, body: "unavailable" });
    if (response === "json") return route.fulfill({
      status: 200,
      headers: { "content-type": "application/json", "cache-control": "no-store" },
      body: "{not-json",
    });
    return route.fulfill({
      status: 200,
      headers: { "content-type": "application/json", "cache-control": response === "cache" ? "public, max-age=60" : "no-store" },
      body: JSON.stringify(response === "missing" ? {} : {
        identity_token: response === "invalid" ? invalidToken : identity_token,
      }),
    });
  });
  await installTokenWidget(page);
  await expect(page.locator("#zaq-widget")).toHaveCount(0);
  const mount = () => page.evaluate(async () => {
    try {
      await window.zaq.widget.mountAuthenticated("http://127.0.0.1:4020/widget/420");
      return "mounted";
    } catch (error) {
      return (error as Error).message;
    }
  });
  expect(await mount()).toBe("Widget token endpoint failed.");
  response = "json";
  expect(await mount()).not.toBe("mounted");
  await expect(page.locator("#zaq-widget")).toHaveCount(0);
  response = "missing";
  expect(await mount()).toBe("Widget token endpoint did not return identity_token.");
  await expect(page.locator("#zaq-widget")).toHaveCount(0);
  response = "cache";
  expect(await mount()).toBe("Widget token endpoint must return Cache-Control: no-store.");
  await expect(page.locator("#zaq-widget")).toHaveCount(0);
  response = "invalid";
  expect(await mount()).toBe("mounted");
  const widget = page.frameLocator("#zaq-widget");
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "false");
  await expect(widget.locator(".zaq-widget")).toHaveCount(0);
  response = "valid";
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true", { timeout: 10_000 });
  await expect(widget.locator(".zaq-widget")).toBeVisible();
});

for (const failure of ["expiry", "store", "reset"] as const) {
  test(`selected conversation survives failed ${failure} reconnect authentication`, async ({ page, request }) => {
    const control = "http://127.0.0.1:4021";
    const user = `resume-${failure}-${crypto.randomUUID()}`;
    let tokens = 0;
    let offline = false;
    let recovering = false;
    let expiry = 0;
    let initialCredential = "";
    await page.route("**/api/widget-token", async route => {
      // Do not let proactive renewal replace the token whose expiry we test.
      if (offline || (failure === "expiry" && tokens > 0 && !recovering)) {
        return route.fulfill({ status: 503, body: "offline" });
      }
      const response = await request.get(`${control}/identity`, { params: {
        user_id: user, ...(tokens === 0 && failure === "expiry" ? { ttl: "8" } : {}),
      } });
      const { identity_token } = await response.json();
      if (tokens === 0) {
        const claims = JSON.parse(Buffer.from(identity_token.split(".")[1], "base64url").toString());
        expiry = claims.exp;
        initialCredential = claims.jti;
      }
      tokens++;
      await route.fulfill({ headers: { "cache-control": "no-store" }, json: { identity_token } });
    });
    const requests = async (): Promise<any[]> => (await request.get(`${control}/requests/${user}`)).json();
    await installTokenWidget(page);
    const widget = page.frameLocator("#zaq-widget");
    await expect.poll(() => tokens).toBe(1);
    await expect(widget.locator("#widget-context")).toHaveAttribute("data-auth-credential-id", initialCredential);
    await expect(widget.locator("#widget-context")).toHaveAttribute("data-auth-expires-at", String(expiry));
    const input = widget.getByRole("textbox", { name: "Message", exact: true });
    await input.fill("reconnect first");
    await input.press("Enter");
    await expect(widget.getByText("Answer to reconnect first", { exact: true })).toBeVisible();
    const initial = await requests();
    const { sessions } = await (await request.get(`${control}/liveview-sessions/${user}`)).json();
    const conversation = sessions[0].conversation_id;
    expect(conversation).toMatch(/^e2e-/);
    offline = true;
    await widget.locator("body").evaluate(() => (window as any).liveSocket.disconnect());
    try {
      if (failure === "expiry") {
        await expect.poll(async () => (await (await request.get(`${control}/auth-state`)).json()).now, { timeout: 12_000 }).toBeGreaterThanOrEqual(expiry);
      } else {
        expect((await request.post(`${control}/auth-store/${failure === "store" ? "unavailable" : "reset"}`)).status()).toBe(204);
        if (failure === "store") {
          const state = await request.get(`${control}/auth-state`);
          expect(state.status()).toBe(200);
          expect(await state.json()).toMatchObject({ available: false, cutoff: null });
        }
        if (failure === "reset") await expect.poll(async () => (await (await request.get(`${control}/auth-state`)).json()).available).toBe(true);
      }
      await widget.locator("body").evaluate(() => (window as any).liveSocket.connect());
      await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "false");
      await expect(widget.locator('.zaq-connection[data-state="connected"]')).toHaveCount(0);
      expect(await requests()).toEqual(initial);
      if (failure === "store") expect((await request.post(`${control}/auth-store/restore`)).status()).toBe(204);
      if (failure === "reset") {
        const { cutoff } = await (await request.get(`${control}/auth-state`)).json();
        await expect.poll(async () => (await (await request.get(`${control}/auth-state`)).json()).now).toBeGreaterThan(cutoff);
      }
      expect(tokens).toBe(1);
      recovering = true;
      offline = false;
      await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true", { timeout: 10_000 });
      await expect(widget.locator("#widget-context")).not.toHaveAttribute("data-auth-credential-id", initialCredential);
      await expect(widget.locator(".zaq-widget")).toHaveAttribute("data-reconnecting", "false");
      await expect(widget.getByText("Answer to reconnect first", { exact: true })).toBeVisible();
      await input.fill("reconnect second");
      await input.press("Enter");
      await expect(widget.getByText("Answer to reconnect second", { exact: true })).toBeVisible();
      const final = await requests();
      expect(final.filter(r => r.content)).toHaveLength(2);
      expect(final.find(r => r.content === "reconnect second").conversation_id).toBe(conversation);
      expect(final.filter(r => r.type === "conversation_init" && r.conversation_id === null)).toHaveLength(1);
      expect(final.some(r => r.type === "conversation_history" && r.conversation_id === conversation)).toBe(true);
      expect(tokens).toBe(2);
    } finally {
      if (failure === "store" && !(await (await request.get(`${control}/auth-state`)).json()).available) await request.post(`${control}/auth-store/restore`);
    }
  });
}

test("offline revocation remains terminal after JWT expiry and explicit reload can authenticate", async ({ page, request }) => {
  const control = "http://127.0.0.1:4021";
  const user = `expired-revoked-${crypto.randomUUID()}`;
  let attempts = 0;
  let offline = false;
  let expiry = 0;
  await page.route("**/api/widget-token", async route => {
    attempts++;
    if (offline) return route.fulfill({ status: 503, body: "offline" });
    const { identity_token } = await (await request.get(`${control}/identity`, { params: { user_id: user, ...(attempts === 1 ? { ttl: "8" } : {}) } })).json();
    expiry = JSON.parse(Buffer.from(identity_token.split(".")[1], "base64url").toString()).exp;
    await route.fulfill({ headers: { "cache-control": "no-store" }, json: { identity_token } });
  });
  await installTokenWidget(page);
  const widget = page.frameLocator("#zaq-widget");
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true");
  offline = true;
  await widget.locator("body").evaluate(() => (window as any).liveSocket.disconnect());
  const { proof } = await (await request.get(`${control}/control-proof`, { params: { user_id: user } })).json();
  expect((await request.post("http://127.0.0.1:4020/widget-api/420/disconnect", { headers: { Authorization: `Bearer ${proof}` }, data: { user_id: user } })).status()).toBe(200);
  await expect.poll(async () => (await (await request.get(`${control}/auth-state`)).json()).now, { timeout: 12_000 }).toBeGreaterThanOrEqual(expiry);
  const before = attempts;
  const work = await (await request.get(`${control}/requests/${user}`)).json();
  await widget.locator("body").evaluate(() => (window as any).liveSocket.connect());
  await expect(widget.locator("#widget-backend-revoked")).toHaveText("Refresh the page to reconnect.");
  await page.clock.install();
  await page.clock.runFor(2500);
  expect(attempts).toBe(before);
  expect(await (await request.get(`${control}/requests/${user}`)).json()).toEqual(work);
  offline = false;
  await installTokenWidget(page);
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true");
  await expect(widget.locator("#widget-backend-revoked")).toHaveCount(0);
  expect(attempts).toBe(before + 1);
});
