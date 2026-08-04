import { useEffect, useState } from "react";
import { KiwiGateway } from "./gateway";
import AgentView from "./AgentView";
import Dashboard from "./Dashboard";

declare global {
  interface Window {
    __GATEWAY_TOKEN__?: string;
  }
}

// ponytail: 3 tabs, 2 real → plain useState page switch, no router library
// (per spec — a client-side router would be scaffolding for a single page).
type Page = "dashboard" | "agent" | "chat";

const gateway = new KiwiGateway();

function TopNav({ page, setPage }: { page: Page; setPage: (p: Page) => void }) {
  return (
    <nav id="topnav">
      <button className={page === "dashboard" ? "active" : ""} onClick={() => setPage("dashboard")}>
        DASHBOARD
      </button>
      <button className={page === "agent" ? "active" : ""} onClick={() => setPage("agent")}>
        AGENT
      </button>
      <button className="disabled" disabled title="Wkrótce">
        CHAT
      </button>
    </nav>
  );
}

export default function App() {
  const [page, setPage] = useState<Page>("dashboard");
  const [connected, setConnected] = useState(false);

  useEffect(() => {
    const unsub = gateway.subscribe(() => setConnected(gateway.connected));
    gateway.connect(window.__GATEWAY_TOKEN__ ?? "");
    return unsub;
  }, []);

  return (
    <div id="app-shell">
      <header id="topbar">
        <span id="topbar-title">kiwiMango</span>
        <span className={`dot ${connected ? "alive" : ""}`} />
        <TopNav page={page} setPage={setPage} />
      </header>

      <main id="page-body">
        {page === "dashboard" && <Dashboard />}
        {page === "agent" && <AgentView gateway={gateway} />}
      </main>
    </div>
  );
}
