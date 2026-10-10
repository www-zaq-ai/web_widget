/** One transport session per connector, independent from every iframe's identity. */
export async function widgetSessionToken(
  path: string,
  { verifyOnly = false, signal }: { verifyOnly?: boolean; signal?: AbortSignal } = {},
): Promise<string> {
  const url = new URL(path, location.origin);
  if (url.origin !== location.origin || url.search || url.hash || url.username || url.password) {
    throw new Error("invalid_session_endpoint");
  }
  if (!navigator.locks) throw new Error("session_coordination_unsupported");

  const controller = new AbortController();
  const abort = () => controller.abort();
  signal?.addEventListener("abort", abort, { once: true });
  if (signal?.aborted) controller.abort();
  const timeout = window.setTimeout(() => controller.abort(), 10_000);
  try {
    return await navigator.locks.request(`web-widget-session:${url.pathname}`, {
      mode: "exclusive", signal: controller.signal,
    }, async () => {
      const read = async (verify: boolean) => {
        const target = new URL(url);
        if (verify) target.searchParams.set("verify", "1");
        const response = await fetch(target, {
          credentials: "same-origin", cache: "no-store", signal: controller.signal,
          headers: { Accept: "application/json" },
        });
        if (!response.ok) throw new Error(response.status === 409 ? "cookie_unavailable" : "session_bootstrap_failed");
        if (!response.headers.get("cache-control")?.toLowerCase().includes("no-store")) {
          throw new Error("invalid_session_response");
        }
        const body = await response.json();
        if (typeof body.csrf_token !== "string" || !body.csrf_token) {
          throw new Error("invalid_session_response");
        }
        return body.csrf_token;
      };
      if (!verifyOnly) await read(false);
      // Read-only confirmation: blocked cookies must not cause repeated creation.
      return read(true);
    });
  } finally {
    window.clearTimeout(timeout);
    signal?.removeEventListener("abort", abort);
  }
}
