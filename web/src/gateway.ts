// Thin JSON-RPC client for the Hermes gateway, mirroring the wire protocol
// documented in Sources/kiwiMango/Chat/HermesGatewayClient.swift (lines 1-53).
// ponytail: only the calls/events this UI needs (session.create, prompt.submit,
// message.*, tool.*) — the gateway has ~150 event types, everything else is
// ignored, matching the old single-file hack's scope.
//
// Multi-session: ONE WebSocket connection carries every session — confirmed
// from the protocol doc (HermesGatewayClient.swift lines 1-53): push events
// are `{"jsonrpc":"2.0","method":"event","params":{"type":...,"session_id":...,
// "payload":{...}}}`, i.e. the server tags every event with the session it
// belongs to. So N tabs = N `session.create` calls sharing this.ws, routed by
// `session_id` in `handleEvent`. No `session.close`/`session.list` RPC exists
// in the documented protocol (verified against HermesStateReader.swift's own
// note: "no session.list") — closing a tab only drops it client-side; the
// gateway-side session just goes idle. History is therefore scoped to tabs
// still open in this browser tab (ponytail, matches native app's own gap).

export type ToolPart = {
  type: "tool-call";
  toolCallId: string;
  toolName: string;
  args: Record<string, unknown>;
  argsText: string;
  result?: unknown;
  status: "running" | "complete" | "error";
  durationS?: number;
};

export type TextPart = { type: "text"; text: string };
export type Part = TextPart | ToolPart;

export type ChatMessage = {
  id: string;
  role: "user" | "assistant";
  parts: Part[];
};

// Mirrors AgentSessionController.availableModels (ConversationBackends.swift:73-75).
export const AVAILABLE_MODELS = [
  "kimi-k2.7-code:cloud",
  "glm-5.2:cloud",
  "qwen3.5:cloud",
  "minimax-m3:cloud",
];

const PROVIDER = "ollama-launch";

export type SessionTab = {
  id: string; // gateway session_id, assigned once session.create resolves
  model: string;
  messages: ChatMessage[];
  isRunning: boolean;
};

type Listener = () => void;

export class KiwiGateway {
  private ws: WebSocket | null = null;
  private token = "";
  private reqId = 0;
  private pending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
  private listeners = new Set<Listener>();

  tabs: SessionTab[] = [];
  activeTabId: string | null = null;
  connected = false;

  subscribe(fn: Listener): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  private emit() {
    for (const fn of this.listeners) fn();
  }

  connect(token: string) {
    this.token = token;
    if (this.ws) return;
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    const ws = new WebSocket(`${proto}//${location.host}/api/ws?token=${token}`);
    this.ws = ws;
    ws.onopen = () => {
      this.connected = true;
      this.emit();
      if (this.tabs.length === 0) void this.newTab(AVAILABLE_MODELS[0]);
    };
    ws.onclose = () => {
      this.connected = false;
      this.ws = null;
      this.emit();
      setTimeout(() => this.connect(this.token), 1500);
    };
    ws.onerror = () => ws.close();
    ws.onmessage = (ev) => this.handleMessage(JSON.parse(ev.data));
  }

  private call(method: string, params: Record<string, unknown>): Promise<any> {
    return new Promise((resolve, reject) => {
      if (!this.ws) return reject(new Error("nie połączono z gateway"));
      const id = ++this.reqId;
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    });
  }

  private handleMessage(msg: any) {
    if (msg.id !== undefined && this.pending.has(msg.id)) {
      const { resolve, reject } = this.pending.get(msg.id)!;
      this.pending.delete(msg.id);
      if (msg.error) reject(new Error(msg.error.message));
      else resolve(msg.result);
      return;
    }
    if (msg.method === "event") this.handleEvent(msg.params);
  }

  private tab(id: string): SessionTab | undefined {
    return this.tabs.find((t) => t.id === id);
  }

  private updateTab(id: string, patch: Partial<SessionTab>) {
    this.tabs = this.tabs.map((t) => (t.id === id ? { ...t, ...patch } : t));
  }

  private lastAssistant(tab: SessionTab): ChatMessage | undefined {
    return tab.messages[tab.messages.length - 1]?.role === "assistant"
      ? tab.messages[tab.messages.length - 1]
      : undefined;
  }

  private handleEvent(params: { type: string; session_id?: string; payload?: any }) {
    const { type, session_id, payload } = params;
    if (!session_id) return;
    const tab = this.tab(session_id);
    if (!tab) return; // event for a tab closed client-side, or not ours

    switch (type) {
      case "message.start":
        this.updateTab(tab.id, {
          messages: [...tab.messages, { id: crypto.randomUUID(), role: "assistant", parts: [] }],
          isRunning: true,
        });
        break;
      case "message.delta": {
        const text = payload?.text;
        if (typeof text !== "string") break;
        const last = this.lastAssistant(tab);
        if (!last) break;
        const parts = [...last.parts];
        const lastPart = parts[parts.length - 1];
        if (lastPart?.type === "text") {
          parts[parts.length - 1] = { type: "text", text: lastPart.text + text };
        } else {
          parts.push({ type: "text", text });
        }
        this.replaceLast(tab, { ...last, parts });
        break;
      }
      case "message.complete":
        this.updateTab(tab.id, { isRunning: false });
        break;
      case "tool.start": {
        const last = this.lastAssistant(tab);
        if (!last || !payload) break;
        const part: ToolPart = {
          type: "tool-call",
          toolCallId: payload.tool_id,
          toolName: payload.name,
          args: {},
          argsText: "",
          status: "running",
        };
        this.replaceLast(tab, { ...last, parts: [...last.parts, part] });
        break;
      }
      case "tool.complete": {
        const last = this.lastAssistant(tab);
        if (!last || !payload) break;
        const parts = last.parts.map((p): Part =>
          p.type === "tool-call" && p.toolCallId === payload.tool_id
            ? {
                ...p,
                args: payload.args ?? {},
                argsText: JSON.stringify(payload.args ?? {}),
                result: payload.result,
                status: payload.result?.error ? "error" : "complete",
                durationS: payload.duration_s,
              }
            : p
        );
        this.replaceLast(tab, { ...last, parts });
        break;
      }
      default:
        break; // ignore the other ~150 event types
    }
    this.emit();
  }

  private replaceLast(tab: SessionTab, msg: ChatMessage) {
    this.updateTab(tab.id, { messages: [...tab.messages.slice(0, -1), msg] });
  }

  async newTab(model: string): Promise<string> {
    const result = await this.call("session.create", { model, provider: PROVIDER, cols: 80 });
    const id: string = result.session_id;
    this.tabs = [...this.tabs, { id, model, messages: [], isRunning: false }];
    this.activeTabId = id;
    this.emit();
    return id;
  }

  closeTab(id: string) {
    this.tabs = this.tabs.filter((t) => t.id !== id);
    if (this.activeTabId === id) {
      this.activeTabId = this.tabs[this.tabs.length - 1]?.id ?? null;
    }
    this.emit();
  }

  selectTab(id: string) {
    this.activeTabId = id;
    this.emit();
  }

  async send(tabId: string, text: string) {
    const tab = this.tab(tabId);
    if (!tab) return;
    this.updateTab(tabId, {
      messages: [...tab.messages, { id: crypto.randomUUID(), role: "user", parts: [{ type: "text", text }] }],
    });
    this.emit();
    try {
      await this.call("prompt.submit", { session_id: tabId, text });
    } catch (e) {
      const current = this.tab(tabId);
      if (!current) return;
      this.updateTab(tabId, {
        messages: [
          ...current.messages,
          { id: crypto.randomUUID(), role: "assistant", parts: [{ type: "text", text: `⚠️ ${(e as Error).message}` }] },
        ],
      });
      this.emit();
    }
  }
}
