import { expect, test } from "@playwright/test";

for (const prefix of ["/widget", "/support/chat"]) {
  test(`host endpoint renders React, styles and hooks at ${prefix}`, async ({ page }) => {
    const errors: string[] = [];
    const assets: string[] = [];
    const sockets: string[] = [];
    page.on("pageerror", error => errors.push(error.message));
    page.on("response", response => {
      if (response.url().includes("/web_widget/assets/") && response.ok()) assets.push(response.url());
    });
    page.on("websocket", socket => sockets.push(socket.url()));
    const embed = await page.request.get("http://127.0.0.1:4020/web_widget/assets/embed.js");
    expect(embed.ok()).toBe(true);
    expect(embed.headers()["content-type"]).toContain("javascript");
    await page.goto("http://127.0.0.1:4020/widget/missing");
    await page.evaluate((prefix) => {
      const frame = document.createElement("iframe");
      frame.id = "host-widget";
      window.addEventListener("message", event => {
        if (event.source === frame.contentWindow && event.data?.type === "zaq.widget.ready") {
          frame.contentWindow!.postMessage({ type: "zaq.widget.init", user_id: "host-user" }, location.origin);
        }
      });
      frame.src = prefix + "/demo";
      document.body.append(frame);
    }, prefix);
    const widget = page.frameLocator("#host-widget");
    const input = widget.getByRole("textbox", { name: "Message", exact: true });
    await expect(input).toBeVisible();
    await expect(widget.locator("body")).toHaveCSS("background-color", "rgba(0, 0, 0, 0)");
    await input.fill("Host question");
    await input.press("Enter");
    await expect(widget.locator(".zaq-widget")).toHaveAttribute("aria-label", "Website assistant");
    await expect(widget.locator(".zaq-widget-header h1, .zaq-header-identity")).toHaveCount(0);
    await expect(widget.getByRole("button", { name: "Close chat", exact: true })).toBeVisible();
    await expect(widget.locator('[data-role="assistant"]')).toContainText("prototype response");
    expect(assets.some(url => url.endsWith("/app.js"))).toBe(true);
    expect(assets.some(url => url.endsWith("/app.css"))).toBe(true);
    expect(sockets.length).toBeGreaterThan(0);
    const widgetSockets = sockets.filter(url => url.includes(`${prefix}/demo/live/`));
    expect(widgetSockets.length).toBeGreaterThan(0);
    expect(widgetSockets.every(url => url.startsWith(`ws://127.0.0.1:4020${prefix}/demo/live/websocket`))).toBe(true);
    expect(errors).toEqual([]);
  });
}
