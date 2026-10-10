import { expect, test } from "@playwright/test";
import { WidgetSessionConnection } from "../js/widget-session-connection";

class Clock {
  private next = 0;
  private now = 0;
  private timers = new Map<number, { at: number; callback: () => void }>();
  setTimeout = (callback: () => void, ms: number) => {
    const id = ++this.next;
    this.timers.set(id, { at: this.now + ms, callback });
    return id;
  };
  clearTimeout = (id: number) => { this.timers.delete(id); };
  advance(ms: number) {
    this.now += ms;
    for (const [id, timer] of this.timers) {
      if (timer.at <= this.now) { this.timers.delete(id); timer.callback(); }
    }
  }
}

async function settle() { for (let i = 0; i < 10; i++) await Promise.resolve(); }

function fixture(prepare?: (verify: boolean, signal: AbortSignal) => Promise<void>) {
  const clock = new Clock();
  const requests: boolean[] = [];
  const failures: string[] = [];
  let connections = 0;
  let disconnects = 0;
  const connection = new WidgetSessionConnection({
    prepare: async (verify, signal) => { requests.push(verify); await prepare?.(verify, signal); },
    connect: () => { connections++; },
    disconnect: () => { disconnects++; },
    failure: error => failures.push(error.message),
  }, clock);
  return { clock, requests, failures, connection, connections: () => connections, disconnects: () => disconnects };
}

test("open/error cycles cannot reset document recovery or initialize cookies again", async () => {
  const f = fixture();
  f.connection.start();
  f.connection.start();
  await settle();
  for (let i = 0; i < 10; i++) {
    // Even actual LiveView establishment does not reset the resynchronization budget.
    f.connection.established();
    f.connection.error();
    await settle();
  }
  expect(f.requests).toEqual([false, true, true, true]);
  expect(f.failures).toEqual(["session_connection_failed"]);
  expect(f.connections()).toBe(4);
});

test("the initial deadline includes bootstrap and LiveView establishment", async () => {
  let finish!: () => void;
  let signal!: AbortSignal;
  const f = fixture(async (_verify, pending) => {
    signal = pending;
    await new Promise<void>(resolve => { finish = resolve; });
  });
  f.connection.start();
  f.clock.advance(10_000);
  expect(f.failures).toEqual(["session_connection_failed"]);
  expect(signal.aborted).toBe(true);
  finish();
  await settle();
  expect(f.connections()).toBe(0);
});

test("successful bootstrap and repeated transport errors cannot extend the initial deadline", async () => {
  const f = fixture();
  f.connection.start();
  await settle();
  f.clock.advance(9_000);
  f.connection.error();
  await settle();
  f.clock.advance(1_000);
  expect(f.failures).toEqual(["session_connection_failed"]);
  expect(f.requests).toEqual([false, true]);
});

test("a transient reconnect gets a finite deadline cleared by LiveView establishment", async () => {
  const f = fixture();
  f.connection.start();
  await settle();
  f.connection.established();
  f.clock.advance(20_000);
  expect(f.failures).toEqual([]);
  f.connection.lost();
  f.clock.advance(9_000);
  f.connection.lost();
  f.connection.established();
  f.clock.advance(20_000);
  expect(f.failures).toEqual([]);
  f.connection.lost();
  f.clock.advance(10_000);
  expect(f.failures).toEqual(["session_connection_failed"]);
  expect(f.requests).toEqual([false]);
});

test("read-only recovery failure stops instead of recreating a missing cookie", async () => {
  const f = fixture(async verify => { if (verify) throw new Error("cookie_unavailable"); });
  f.connection.start();
  await settle();
  f.connection.established();
  f.connection.error();
  await settle();
  f.connection.error();
  expect(f.requests).toEqual([false, true]);
  expect(f.failures).toEqual(["cookie_unavailable"]);
});

test("concurrent socket errors share one verification and late results cannot reconnect", async () => {
  let finish!: () => void;
  const f = fixture(async verify => {
    if (verify) await new Promise<void>(resolve => { finish = resolve; });
  });
  f.connection.start();
  await settle();
  f.connection.error();
  f.connection.error();
  expect(f.requests).toEqual([false, true]);
  f.clock.advance(10_000);
  finish();
  await settle();
  expect(f.connections()).toBe(1);
  expect(f.failures).toEqual(["session_connection_failed"]);
});

test("explicit document reload provides a new initialization attempt", async () => {
  const first = fixture(async () => { throw new Error("cookie_unavailable"); });
  first.connection.start();
  await settle();
  first.connection.start();
  expect(first.requests).toEqual([false]);
  const reloaded = fixture();
  reloaded.connection.start();
  await settle();
  expect(reloaded.requests).toEqual([false]);
  expect(reloaded.connections()).toBe(1);
});

test("backend revocation stops recovery without misreporting a session failure", async () => {
  const f = fixture();
  f.connection.start();
  await settle();
  f.connection.established();
  f.connection.stop();
  f.connection.lost();
  f.connection.error();
  f.clock.advance(20_000);
  expect(f.requests).toEqual([false]);
  expect(f.failures).toEqual([]);
});
