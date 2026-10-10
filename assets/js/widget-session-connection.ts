type Actions = {
  prepare: (verifyOnly: boolean, signal: AbortSignal) => Promise<void>;
  connect: () => void;
  disconnect: () => void;
  failure: (error: Error) => void;
};

type Clock = {
  setTimeout: (callback: () => void, ms: number) => number;
  clearTimeout: (timer: number) => void;
};

/** Transport-session recovery only; identity renewal and conversation restoration stay separate. */
export class WidgetSessionConnection {
  private started = false;
  private failed = false;
  private resynchronizing = false;
  private attempts = 0;
  private deadline?: number;
  private readonly controller = new AbortController();

  constructor(private readonly actions: Actions, private readonly clock: Clock = globalThis) {}

  start() {
    if (this.started) return;
    this.started = true;
    this.beginDeadline();
    void this.prepare(false);
  }

  established() {
    if (this.failed) return;
    if (this.deadline !== undefined) this.clock.clearTimeout(this.deadline);
    this.deadline = undefined;
  }

  lost() {
    if (this.started && !this.failed) this.beginDeadline();
  }

  error() {
    if (!this.started || this.failed) return;
    this.beginDeadline();
    if (this.resynchronizing) return;
    if (this.attempts >= 3) {
      this.fail(new Error("session_connection_failed"));
      return;
    }
    this.attempts++;
    this.resynchronizing = true;
    this.actions.disconnect();
    void this.prepare(true).finally(() => { this.resynchronizing = false; });
  }

  stop() {
    this.failed = true;
    this.controller.abort();
    if (this.deadline !== undefined) this.clock.clearTimeout(this.deadline);
    this.deadline = undefined;
  }

  private beginDeadline() {
    if (this.deadline !== undefined) return;
    this.deadline = this.clock.setTimeout(() => this.fail(new Error("session_connection_failed")), 10_000);
  }

  private async prepare(verifyOnly: boolean) {
    try {
      await this.actions.prepare(verifyOnly, this.controller.signal);
      if (!this.failed) this.actions.connect();
    } catch (error) {
      this.fail(error instanceof Error ? error : new Error("session_bootstrap_failed"));
    }
  }

  private fail(error: Error) {
    if (this.failed) return;
    this.stop();
    this.actions.disconnect();
    this.actions.failure(error);
  }
}

let connection: WidgetSessionConnection | undefined;

export function startWidgetSessionConnection(actions: Actions) {
  connection ??= new WidgetSessionConnection(actions);
  connection.start();
  return connection;
}

export function widgetSessionEstablished() { connection?.established(); }
export function widgetSessionLost() { connection?.lost(); }
export function widgetSessionStopped() { connection?.stop(); }
