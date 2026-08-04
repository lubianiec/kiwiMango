import { useEffect, useState } from "react";
import {
  AssistantRuntimeProvider,
  ComposerPrimitive,
  MessagePrimitive,
  ThreadPrimitive,
  useExternalStoreRuntime,
  useMessage,
  type AppendMessage,
  type ThreadMessageLike,
} from "@assistant-ui/react";
import { AVAILABLE_MODELS, type ChatMessage, type KiwiGateway, type ToolPart } from "./gateway";

function convertMessage(m: ChatMessage): ThreadMessageLike {
  const content = m.parts.map((p) =>
    p.type === "text"
      ? { type: "text", text: p.text }
      : {
          type: "tool-call",
          toolCallId: p.toolCallId,
          toolName: p.toolName,
          args: p.args,
          argsText: p.argsText,
          result: p.result,
        }
  );
  return { role: m.role, content: content as unknown as ThreadMessageLike["content"] };
}

function ToolLine({ part }: { part: ToolPart }) {
  const icon = part.status === "running" ? "▶" : part.status === "error" ? "✗" : "✓";
  const dur = part.durationS != null ? ` (${part.durationS.toFixed(1)}s)` : "";
  return (
    <div className="tool-line">
      {icon} {part.toolName}
      {dur}
    </div>
  );
}

function AssistantContent() {
  const content = useMessage((m) => m.content);
  return (
    <>
      {content.map((part, i) =>
        part.type === "text" ? (
          <span key={i} className="body">
            {part.text}
          </span>
        ) : part.type === "tool-call" ? (
          <ToolLine
            key={i}
            part={{
              type: "tool-call",
              toolCallId: part.toolCallId,
              toolName: part.toolName,
              args: (part.args as Record<string, unknown>) ?? {},
              argsText: part.argsText ?? "",
              result: part.result,
              status: part.result !== undefined ? "complete" : "running",
            }}
          />
        ) : null
      )}
    </>
  );
}

function AssistantMessage() {
  return (
    <MessagePrimitive.Root className="msg assistant">
      <span className="label">HERMES</span>
      <AssistantContent />
    </MessagePrimitive.Root>
  );
}

function UserText() {
  const text = useMessage((m) => m.content.map((p) => (p.type === "text" ? p.text : "")).join(""));
  return <span className="body">{text}</span>;
}

function UserMessage() {
  return (
    <MessagePrimitive.Root className="msg user">
      <span className="label">TY</span>
      <UserText />
    </MessagePrimitive.Root>
  );
}

export default function AgentView({ gateway }: { gateway: KiwiGateway }) {
  const [, force] = useState(0);
  const [nextModel, setNextModel] = useState(AVAILABLE_MODELS[0]);

  useEffect(() => gateway.subscribe(() => force((n) => n + 1)), [gateway]);

  const tabs = gateway.tabs;
  const activeTab = tabs.find((t) => t.id === gateway.activeTabId) ?? tabs[0];

  const onNew = async (message: AppendMessage) => {
    if (!activeTab) return;
    const text = message.content.map((c) => (c.type === "text" ? c.text ?? "" : "")).join("");
    if (text.trim()) await gateway.send(activeTab.id, text);
  };

  const runtime = useExternalStoreRuntime({
    messages: activeTab?.messages ?? [],
    isRunning: activeTab?.isRunning ?? false,
    onNew,
    convertMessage,
  });

  return (
    <div id="agent-view">
      <div id="tabs-bar">
        {tabs.map((t) => (
          <button
            key={t.id}
            className={`tab-chip ${t.id === activeTab?.id ? "active" : ""}`}
            onClick={() => gateway.selectTab(t.id)}
          >
            <span className="tab-dot" />
            <span className="tab-model">{t.model.replace(":cloud", "")}</span>
            <span
              className="tab-close"
              onClick={(e) => {
                e.stopPropagation();
                gateway.closeTab(t.id);
              }}
            >
              ✕
            </span>
          </button>
        ))}
        <select
          id="model-select"
          value={nextModel}
          onChange={(e) => setNextModel(e.target.value)}
          title="Model dla nowej sesji"
        >
          {AVAILABLE_MODELS.map((m) => (
            <option key={m} value={m}>
              {m.replace(":cloud", "")}
            </option>
          ))}
        </select>
        <button id="new-tab-btn" onClick={() => void gateway.newTab(nextModel)}>
          +
        </button>
      </div>

      <AssistantRuntimeProvider runtime={runtime}>
        <ThreadPrimitive.Root>
          <ThreadPrimitive.Viewport id="messages">
            <ThreadPrimitive.Messages components={{ UserMessage, AssistantMessage }} />
          </ThreadPrimitive.Viewport>
          <ComposerPrimitive.Root id="composer">
            <ComposerPrimitive.Input id="input" rows={1} placeholder="Napisz wiadomość…" autoFocus />
            <ComposerPrimitive.Send id="send-btn">Wyślij</ComposerPrimitive.Send>
          </ComposerPrimitive.Root>
        </ThreadPrimitive.Root>
      </AssistantRuntimeProvider>
    </div>
  );
}
