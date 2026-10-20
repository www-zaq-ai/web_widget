import { createContext, useContext, useEffect, useId, useRef, useState, useSyncExternalStore, type ComponentPropsWithoutRef } from "react";
import { useLiveReact } from "live_react";
import {
  AssistantRuntimeProvider,
  MessagePrimitive,
  ThreadPrimitive,
  TextMessagePartProvider,
  useAuiState,
  useExternalStoreRuntime,
  type ThreadMessageLike,
} from "@assistant-ui/react";
import { MarkdownTextPrimitive } from "@assistant-ui/react-markdown";
import remarkGfm from "remark-gfm";
import "../css/widget.css";
import { connectionSnapshot, subscribeConnection } from "../js/widget-connection";
import { ConversationProgress, WorkingIndicator } from "./working-indicator";
import { SubmissionController } from "../js/submission";
import { AcknowledgedComposer } from "./acknowledged-composer";

type Mode = "launcher" | "conversation";
type Step = {
  id: string;
  kind: "reasoning" | "tool_call" | "tool_result" | "status";
  label: string;
  content?: string | null;
  state: "started" | "updated" | "completed" | "failed" | "unknown";
  sequence?: number;
  duration_ms?: number;
};
type Activity = { complete: string; running: string; failed: string };
type Message = { activity?: Activity; timestamp?: string; dateSeparator?: string; id: string; role: "user" | "assistant"; content: string; steps?: Step[]; status?: "running" | "complete" | "failed"; error?: string | null };
type Config = {
  locale: string;
  theme: "auto" | "light" | "dark";
  strings: Record<string, string>;
  title: string;
  multiple_conversations?: boolean;
  placeholder: string;
  follow_up_placeholder: string;
  max_length: number;
};
type ConversationSummary = { id: string; title: string };
type Props = { canReopen?: boolean; conversations?: ConversationSummary[]; conversationId?: string | null; mode: Mode; messages: Message[]; isRunning: boolean; submissionPending?: boolean; submissionBlocked?: boolean; isTyping: boolean; authenticationPending?: boolean; responseError?: string | null; config: Config };
type MessageDelta = { conversation_id: string; id: string; delta: string };
type MessageReset = { all?: boolean; conversation_id?: string | null; id?: string };
const messageKey = (conversationId: string | null, id: string) => JSON.stringify([conversationId, id]);

const I18n = createContext<Pick<Config, "locale" | "strings"> | null>(null);
function useI18n() {
  const value = useContext(I18n);
  if (!value) throw new Error("Missing widget localization");
  return value;
}

const convertMessage = (message: Message, fallbackError: string): ThreadMessageLike => ({
  id: message.id,
  role: message.role,
  content: message.content,
  metadata: { custom: { activity: message.activity, steps: message.steps, error: message.error, hasContent: message.content.length > 0, timestamp: message.timestamp, dateSeparator: message.dateSeparator } },
  ...(message.role === "assistant" && {
    status: message.status === "running"
      ? { type: "running" as const }
      : message.status === "failed"
        ? { type: "incomplete" as const, reason: "error" as const, error: message.error || fallbackError }
        : { type: "complete" as const, reason: "stop" as const },
  }),
});

const calendarDay = (date: Date) => `${date.getFullYear()}-${date.getMonth()}-${date.getDate()}`;
const messageDay = (timestamp?: string) => timestamp ? calendarDay(new Date(timestamp)) : undefined;
function dateLabel(timestamp: string, locale: string, t: Record<string, string>) {
  const date = new Date(timestamp);
  const today = new Date();
  const yesterday = new Date(today);
  yesterday.setDate(today.getDate() - 1);
  if (calendarDay(date) === calendarDay(today)) return t["Today"];
  if (calendarDay(date) === calendarDay(yesterday)) return t["Yesterday"];
  return date.toLocaleDateString(locale, { month: "short", day: "numeric", year: "numeric" });
}

export function WebWidget({ mode, messages, isRunning, submissionPending = isRunning, submissionBlocked = false, isTyping, authenticationPending = false, responseError, config, conversations = [], conversationId = null, canReopen = false }: Props) {
  const { pushEvent } = useLiveReact();
  const t = config.strings;
  const connection = useSyncExternalStore(subscribeConnection, connectionSnapshot);
  const [error, setError] = useState<string | null>(null);
  const runtimeRef = useRef<ReturnType<typeof useExternalStoreRuntime> | null>(null);
  const sendOptions = useRef({ pushEvent, t });
  sendOptions.current = { pushEvent, t };
  const submissionRef = useRef<SubmissionController | null>(null);
  if (!submissionRef.current) submissionRef.current = new SubmissionController({
    getDraft: () => runtimeRef.current?.thread.composer.getState().text ?? "",
    setDraft: text => runtimeRef.current?.thread.composer.setText(text),
    send: (text, id, reply) => sendOptions.current.pushEvent("widget.submit", { text, submission_id: id }, value => reply({
      ok: value.ok === true, error: typeof value.error === "string" ? value.error : undefined,
      outcome: typeof value.ok === "boolean" ? value.outcome : "unknown",
    })),
    unknownMessage: t["Submission outcome is unknown. Restore the conversation before sending again."],
    timeoutMessage: t["Submission acknowledgement timed out. Its outcome is unknown. Restore the conversation before sending again."],
  });
  const controller = submissionRef.current;
  const submission = useSyncExternalStore(controller.subscribe, controller.getSnapshot, controller.getSnapshot);
  const submitting = submission.pending != null;
  const submissionUnknown = submission.pending?.status === "unknown";
  const sendDraft = () => {
    if (submissionBlocked || authenticationPending || !connectionSnapshot().ready) return;
    setError(null);
    controller.submit();
  };
  useEffect(() => {
    const acknowledge = (event: Event) => {
      const id = (event as CustomEvent<{ submission_id: string }>).detail?.submission_id;
      if (typeof id === "string") controller.acknowledge(id);
    };
    window.addEventListener("phx:widget.submission.ack", acknowledge);
    return () => { window.removeEventListener("phx:widget.submission.ack", acknowledge); controller.dispose(); };
  }, [controller]);
  useEffect(() => { if (!connection.ready) controller.disconnected(); }, [connection.ready, controller]);
  const [deltas, setDeltas] = useState<Record<string, string>>({});
  useEffect(() => {
    const append = (event: Event) => {
      const { conversation_id, id, delta } = (event as CustomEvent<MessageDelta>).detail;
      const key = messageKey(conversation_id, id);
      setDeltas(current => ({ ...current, [key]: (current[key] || "") + delta }));
    };
    const reset = (event: Event) => {
      const { all, conversation_id, id } = (event as CustomEvent<MessageReset>).detail;
      if (all) return setDeltas({});
      if (!id) return;
      setDeltas(current => {
        const next = { ...current };
        delete next[messageKey(conversation_id ?? null, id)];
        return next;
      });
    };
    window.addEventListener("phx:widget.message.delta", append);
    window.addEventListener("phx:widget.message.reset", reset);
    return () => {
      window.removeEventListener("phx:widget.message.delta", append);
      window.removeEventListener("phx:widget.message.reset", reset);
    };
  }, []);
  const root = useRef<HTMLDivElement>(null);
  const previousMode = useRef(mode);
  const previousConversation = useRef(conversationId);
  const [today, setToday] = useState(() => calendarDay(new Date()));
  useEffect(() => {
    const timer = window.setInterval(() => setToday(calendarDay(new Date())), 60000);
    return () => window.clearInterval(timer);
  }, []);
  let previousDay: string | undefined;
  const datedMessages = messages.map(message => {
    const day = messageDay(message.timestamp);
    const dateSeparator = message.timestamp && day !== previousDay
      ? dateLabel(message.timestamp, config.locale, t) : undefined;
    if (day) previousDay = day;
    return { ...message, content: message.content + (deltas[messageKey(conversationId, message.id)] || ""), dateSeparator };
  });

  // LiveView is the source of truth. This runtime only adapts its props for assistant-ui.
  const runtime = useExternalStoreRuntime({
    messages: datedMessages,
    convertMessage: message => convertMessage(message, t["Unable to complete response"]),
    isRunning,
    isSendDisabled: submitting || submissionPending || submissionBlocked || submissionUnknown || authenticationPending || !connection.ready,
    onNew: async (message) => {
      const text = message.content
        .filter((part) => part.type === "text")
        .map((part) => part.text)
        .join("\n")
        .trim();
      if (!text) return;
      if (!runtimeRef.current?.thread.composer.getState().text) runtimeRef.current?.thread.composer.setText(text);
      sendDraft();
    },
  });
  runtimeRef.current = runtime;

  useEffect(() => {
    if (window.parent === window || !root.current) return;
    const notify = () => window.parent.postMessage({
      type: "zaq.widget.resize",
      mode,
      // The only cross-window data is layout intent, never messages or credentials.
      height: mode === "launcher" ? Math.ceil(root.current!.getBoundingClientRect().height) + 32 : "100%",
    }, "*");
    const observer = new ResizeObserver(notify);
    observer.observe(root.current);
    notify();
    return () => observer.disconnect();
  }, [mode]);

  useEffect(() => {
    if (previousMode.current !== mode) {
      root.current?.querySelector<HTMLElement>(mode === "launcher" ? "[data-widget-reopen]" : ".zaq-composer-input")?.focus();
      previousMode.current = mode;
    }
  }, [mode]);

  useEffect(() => {
    if (previousConversation.current !== conversationId) {
      // Initial host binding may accompany a rejected first submission. Keep its
      // restored draft and error; explicit switches away from a chat reset them.
      if (previousConversation.current !== null && !controller.getSnapshot().pending) {
        runtime.thread.composer.setText("");
        setError(null);
      }
      previousConversation.current = conversationId;
    }
  }, [conversationId, runtime]);

  const changeConversation = (event: string, params: { id?: string } = {}) => {
    pushEvent(event, params, reply => {
      if (!reply.ok) setError(reply.error || t["Unable to change conversations."]);
      else setError(null);
    });
  };

  return (
    <I18n.Provider value={config}><AssistantRuntimeProvider runtime={runtime}>
      <ThreadPrimitive.Root ref={root} className="zaq-widget" data-mode={mode} data-language={config.locale} data-theme={config.theme} data-conversation-id={conversationId ?? ""} data-reconnecting={!connection.ready} style={{ colorScheme: config.theme === "auto" ? "light dark" : config.theme }} data-multiple-conversations={!!config.multiple_conversations} data-calendar-day={today} aria-label={config.title}>
        {mode === "conversation" && config.multiple_conversations && <ConversationSidebar conversations={conversations} selectedId={conversationId} disabled={submitting || isRunning || !connection.ready} onSelect={id => changeConversation("widget.conversation.select", { id })} onNew={() => changeConversation("widget.conversation.new")} />}
        <div className="zaq-chat-main" key="chat-main">
        {mode === "conversation" && <Conversation isTyping={isTyping && connection.ready} onClose={() => { if (connection.ready) pushEvent("widget.close", {}); }} empty={messages.length === 0} />}
        {mode === "launcher" && canReopen && <button type="button" className="zaq-reopen" data-widget-reopen onClick={() => pushEvent("widget.open", {})}>{t["Open conversation"]}<span aria-hidden="true">↗</span></button>}
        <FloatingComposer key="composer" mode={mode} config={config} busy={submitting || submissionPending || submissionBlocked || submissionUnknown || authenticationPending} sending={submitting} draftLocked={submitting} onSend={sendDraft} recoveringResponse={submitting || submissionPending || isRunning} error={submission.error || error || responseError || null} />
        </div>
      </ThreadPrimitive.Root>
    </AssistantRuntimeProvider></I18n.Provider>
  );
}

function ConversationSidebar({ conversations, selectedId, disabled, onSelect, onNew }: { conversations: ConversationSummary[]; selectedId: string | null; disabled: boolean; onSelect: (id: string) => void; onNew: () => void }) {
  const { strings: t } = useI18n();
  return <aside className="zaq-conversations" aria-label={t["Conversations"]}>
    <button className="zaq-new-chat" type="button" disabled={disabled} onClick={onNew}><span aria-hidden="true">＋</span>{t["New chat"]}</button>
    <h2>{t["Your conversations"]}</h2>
    <nav aria-label={t["Conversation history"]}>
      {conversations.map(conversation => <button key={conversation.id} type="button" className="zaq-conversation-item" aria-current={conversation.id === selectedId ? "page" : undefined} disabled={disabled} onClick={() => onSelect(conversation.id)}><bdi>{conversation.title}</bdi></button>)}
    </nav>
    {conversations.length === 0 && <p>{t["No conversations yet."]}</p>}
  </aside>;
}

function FloatingComposer({ mode, config, busy, sending, draftLocked, onSend, recoveringResponse, error }: { mode: Mode; config: Config; busy: boolean; sending: boolean; draftLocked: boolean; onSend: () => void; recoveringResponse: boolean; error: string | null }) {
  const { strings: t } = useI18n();
  const connection = useSyncExternalStore(subscribeConnection, connectionSnapshot);
  return (
    <footer className="zaq-widget-footer">
      {connection.banner && <div className="zaq-connection" data-state={connection.banner}>
        <p role="status" aria-live="polite" aria-atomic="true">
          <span className="zaq-connection-dot" aria-hidden="true" />
          {t[recoveringResponse
            ? "Reconnecting to recover the response…" : "Connection lost. Reconnecting…"]}
        </p>
      </div>}
      {error && <p className="zaq-widget-error" role="alert">{error}</p>}
      <AcknowledgedComposer ready={connection.ready} busy={busy} sending={sending} draftLocked={draftLocked} onSend={onSend}
        placeholder={mode === "launcher" ? config.placeholder : config.follow_up_placeholder} maxLength={config.max_length}
        labels={{ input: t["Message"], send: t["Send"], sending: t["Sending…"], working: t["Working…"], sendMessage: t["Send message"] }} />
      <div className="zaq-widget-signature" dir="ltr">
        <a href="https://www.zaq.ai/open-source" target="_blank" rel="noopener noreferrer">
          Powered by <span>ZAQ.AI</span>
        </a>
      </div>
    </footer>
  );
}

function Conversation({ isTyping, onClose, empty }: { isTyping: boolean; onClose: () => void; empty: boolean }) {
  const { strings: t } = useI18n();
  return (
    <>
      <header className="zaq-widget-header">
        <div className="zaq-header-actions">
          {isTyping && <span className="zaq-header-status" role="status"><span className="zaq-live-dot" />{t["Assistant is working…"]}</span>}
          <button type="button" className="zaq-close" aria-label={t["Close chat"]} title={t["Close chat"]} onClick={onClose}><ActivityIcon kind="close" /></button>
        </div>
      </header>
      <ThreadPrimitive.Viewport className="zaq-thread" aria-label={t["Conversation"]}>
        <div className="zaq-thread-content">
          {empty && <div className="zaq-empty-chat"><h2>{t["How can I help?"]}</h2><p>{t["Start a new conversation or choose one from your history."]}</p></div>}
          <ThreadPrimitive.Messages components={{ UserMessage, AssistantMessage }} />
          <ConversationProgress isTyping={isTyping} label={t["Preparing your answer"]} />
          <ThreadPrimitive.ScrollToBottom className="zaq-scroll-bottom">{t["Latest messages"]}</ThreadPrimitive.ScrollToBottom>
        </div>
      </ThreadPrimitive.Viewport>
    </>
  );
}

function UserMessage() {
  return <><MessageDate /><MessagePrimitive.Root className="zaq-message zaq-message-user" data-role="user"><span className="zaq-user-content" dir="auto"><MessagePrimitive.Parts /></span><MessageTime /></MessagePrimitive.Root></>;
}

function MarkdownLink({ href, title, children }: ComponentPropsWithoutRef<"a">) {
  return <a href={href} title={title} target="_blank" rel="noopener noreferrer">{children}</a>;
}

const markdownComponents = { a: MarkdownLink };

function AssistantMarkdown() {
  return <MarkdownTextPrimitive className="zaq-markdown" smooth={false} remarkPlugins={[remarkGfm]} components={markdownComponents} />;
}

function AssistantMessage() {
  const { strings: t } = useI18n();
  const steps = useAuiState((s) => s.message.metadata.custom.steps) as Step[] | undefined;
  const error = useAuiState((s) => s.message.metadata.custom.error) as string | null | undefined;
  const running = useAuiState((s) => s.message.status?.type === "running");
  const hasContent = useAuiState((s) => s.message.metadata.custom.hasContent) as boolean;
  const optimistic = useAuiState(s => s.message.metadata.isOptimistic === true);
  const toolSteps = steps?.filter(step => step.kind === "tool_call" || step.kind === "tool_result");
  const activeTools = toolSteps?.some(step =>
    (step.state === "started" || step.state === "updated"));
  if (optimistic) return null;
  return (
    <><MessageDate />
    <MessagePrimitive.Root className="zaq-message zaq-message-assistant" data-role="assistant" data-running={running}>
      <div className="zaq-answer-heading"><span className="zaq-assistant-mark zaq-assistant-mark-small" aria-hidden="true"><ActivityIcon kind="assistant" /></span><span>{t["Assistant"]}</span></div>
      {!!toolSteps?.length && <ResponseActivity steps={toolSteps} running={running} failed={!!error} />}
      <div dir="auto" className="zaq-answer-content" data-streaming={running && hasContent}>
        <MessagePrimitive.Parts components={{ Text: AssistantMarkdown }} />
      </div>
      <MessageTime />
      {running && <WorkingIndicator label={hasContent ? t["Writing response"] : activeTools ? t["Working with tools"] : t["Preparing your answer"]} />}
      {error && <div className="zaq-response-error" role="alert"><ActivityIcon kind="failed" /><div><strong>{t["Couldn't finish this response"]}</strong><TextMessagePartProvider text={error}><AssistantMarkdown /></TextMessagePartProvider><span>{t["You can send another message below."]}</span></div></div>}
    </MessagePrimitive.Root></>
  );
}

function MessageDate() {
  const label = useAuiState(s => s.message.metadata.custom.dateSeparator) as string | undefined;
  return label ? <div className="zaq-date-separator" role="separator" aria-label={label}><span>{label}</span></div> : null;
}

function MessageTime() {
  const { locale } = useI18n();
  const timestamp = useAuiState(s => s.message.metadata.custom.timestamp) as string | undefined;
  if (!timestamp) return null;
  const date = new Date(timestamp);
  return <time className="zaq-message-time" dateTime={timestamp} title={date.toLocaleString(locale)}>{date.toLocaleTimeString(locale, { hour: "numeric", minute: "2-digit" })}</time>;
}

function ResponseActivity({ steps, running, failed }: { steps: Step[]; running: boolean; failed: boolean }) {
  const { strings: t } = useI18n();
  const [expanded, setExpanded] = useState<boolean | null>(null);
  const contentId = useId();
  const toggle = useRef<HTMLButtonElement>(null);
  const panel = useRef<HTMLDivElement>(null);
  const wasRunning = useRef(running);
  const failedCount = steps.filter(step => step.state === "failed").length;
  const hasFailure = failed || failedCount > 0;
  const open = expanded ?? (running || hasFailure);

  useEffect(() => {
    if (wasRunning.current && !running) {
      // Keep keyboard focus reachable when completed activity folds away.
      if (!hasFailure && panel.current?.contains(document.activeElement)) toggle.current?.focus();
      setExpanded(null);
    }
    wasRunning.current = running;
  }, [running, hasFailure]);

  const title = hasFailure ? t["Activity needs attention"] : running ? t["Working on your request"] : t["View response activity"];
  const activity = useAuiState(s => s.message.metadata.custom.activity) as Activity;
  const detail = hasFailure ? activity.failed : running ? activity.running : activity.complete;

  return (
    <section className="zaq-activity" data-status={hasFailure ? "failed" : running ? "running" : "complete"} aria-label={t["Response activity"]}>
      <button ref={toggle} type="button" className="zaq-activity-toggle" aria-expanded={open} aria-controls={contentId} onClick={() => setExpanded(!open)}>
        <span className="zaq-activity-symbol"><ActivityIcon kind={hasFailure ? "failed" : running ? "running" : "complete"} /></span>
        <span className="zaq-activity-heading"><strong>{title}</strong><span>{detail}</span></span>
        <span className="zaq-chevron" data-open={open}><ActivityIcon kind="chevron" /></span>
      </button>
      <div ref={panel} id={contentId} className="zaq-activity-steps" hidden={!open}>
        {steps.map(step => <ResponseStep key={step.id} step={step} />)}
      </div>
    </section>
  );
}

function ResponseStep({ step }: { step: Step }) {
  const { strings: t } = useI18n();
  const isTool = step.kind === "tool_call" || step.kind === "tool_result";
  const running = step.state === "started" || step.state === "updated";
  const status = running ? "running" : step.state === "completed" ? "complete" : step.state === "unknown" ? "unknown" : "failed";
  const kind = { tool_call: t["Tool call"], tool_result: t["Tool result"], reasoning: t["Reasoning"], status: t["Activity"] }[step.kind];
  return (
    <details className="zaq-response-step" data-kind={step.kind} data-status={status} data-step-id={step.id} open={step.state === "failed" ? true : undefined}>
      <summary>
        <span className="zaq-tool-icon"><ActivityIcon kind={status === "running" ? "running" : status === "failed" ? "failed" : isTool ? "tool" : "complete"} /></span>
        <span className="zaq-tool-heading"><span className="zaq-tool-kind">{kind}</span><strong dir="auto">{step.label}</strong></span>
        <span className="zaq-step-state">{step.duration_ms !== undefined && `${step.duration_ms} ms · `}{running ? t["Running"] : step.state === "completed" ? t["Done"] : step.state === "unknown" ? (t["Unknown"] || "Unknown") : t["Failed"]}</span>
        <span className="zaq-chevron"><ActivityIcon kind="chevron" /></span>
      </summary>
      <div className="zaq-tool-output"><span className="zaq-output-label">{running ? t["Progress"] : step.state === "failed" ? t["Error details"] : t["Result"]}</span><p dir="auto">{step.content || (step.state === "unknown" ? (t["Tool outcome unavailable"] || "Tool outcome unavailable") : running ? isTool ? t["Waiting for the tool to return a result…"] : t["Preparing your answer"] : step.state === "failed" ? t["This step could not be completed."] : t["This step finished without additional output."])}</p></div>
    </details>
  );
}

function ActivityIcon({ kind }: { kind: "assistant" | "tool" | "running" | "complete" | "failed" | "chevron" | "close" }) {
  if (kind === "running") return <span className="zaq-spinner" aria-hidden="true" />;
  const paths = {
    assistant: "M12 3l2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5L12 3Z",
    tool: "m8 7-5 5 5 5m8-10 5 5-5 5m-3-14-2 18",
    complete: "m5 12 4 4L19 6",
    failed: "M12 8v5m0 3v.01M10 3h4l7 16H3L10 3Z",
    chevron: "m8 5 7 7-7 7",
    close: "m6 6 12 12M18 6 6 18",
  };
  return <svg aria-hidden="true" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><path d={paths[kind]} /></svg>;
}
