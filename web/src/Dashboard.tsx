import { useEffect, useState } from "react";

// MARK: - Dashboard (web) — full port of the native "Zużycie" dashboard.
// Source of truth for every field: StaticWebServer.serveStatus (Swift) —
// reuses DashboardStore/CostsBlock/HardwareMonitor/ProcessSection's own
// readers/formulas, this component only renders what they already computed.

type TokenStats = {
  today: number | null;
  todayTrendPercent: number | null;
  sevenDay: number;
  month: number;
  monthTrendPercent: number | null;
  allTime: number;
};

type DayTotal = { day: string; total: number };
type ModelShare = { model: string; total: number };

type Costs = {
  nbpUsdRate: number | null;
  nbpEurRate: number | null;
  paidZl: number | null;
  apiValueZl: number | null;
  apiValueEur: number | null;
  savingsPercent: number | null;
};

type Hardware = {
  cpuPercent: number | null;
  gpuPercent: number | null;
  ramUsedGB: number | null;
  ramTotalGB: number;
  ssdAvailableGB: number | null;
  ssdTotalGB: number | null;
  netDownMBs: number | null;
  netUpMBs: number | null;
};

type Process = { name: string; pid: number; cpuPercent: number; ramMB: number };

type Status = {
  gatewayAlive: boolean;
  activeModel: string | null;
  ollamaAlive: boolean;
  appVersion: string;
  activeAgents: number;
  tokens: TokenStats;
  last7Days: DayTotal[];
  modelShare7d: ModelShare[];
  costs: Costs;
  hardware: Hardware;
  processes: Process[];
};

// Mirrors formatCompactTokens in Sources/kiwiMango/DesignSystem.swift:192.
function formatCompactTokens(n: number): string {
  const abs = Math.abs(n);
  const sign = n < 0 ? "-" : "";
  if (abs >= 1_000_000) return sign + (abs / 1_000_000).toFixed(1).replace(".", ",") + "M";
  if (abs >= 1_000) return sign + Math.round(abs / 1_000) + "k";
  return String(n);
}

function plNumber(value: number, decimals: number): string {
  return value.toFixed(decimals).replace(".", ",");
}

// Mirrors weekdayColor(for:) in Sources/kiwiMango/Dashboard/CostsBlock.swift:6-9.
const WEEKDAY_COLORS = ["var(--accent)", "var(--blue)", "var(--teal)", "var(--rose)", "var(--green)", "var(--danger)", "var(--core-p)"];

function weekdayAbbrev(day: string): string {
  const d = new Date(`${day}T00:00:00`);
  return ["N", "P", "W", "Ś", "C", "P", "S"][d.getDay()];
}

function trendText(percent: number | null): string {
  if (percent == null) return "—";
  return percent >= 0 ? `▲ ${percent}%` : `▼ ${-percent}%`;
}

function fmtBytes(mb: number): string {
  return mb >= 1024 ? `${(mb / 1024).toFixed(1)} GB` : `${Math.round(mb)} MB`;
}

// MARK: - Ring / donut SVG helpers (no charting library — plain stroke-dasharray, ponytail rung 3/4)

function Ring({ percent, color, size = 52, stroke = 4 }: { percent: number; color: string; size?: number; stroke?: number }) {
  const r = (size - stroke) / 2;
  const c = 2 * Math.PI * r;
  const dash = Math.max(0, Math.min(percent, 100)) / 100 * c;
  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`}>
      <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke="var(--ring-track)" strokeWidth={stroke} />
      <circle
        cx={size / 2}
        cy={size / 2}
        r={r}
        fill="none"
        stroke={color}
        strokeWidth={stroke}
        strokeDasharray={`${dash} ${c - dash}`}
        strokeLinecap="round"
        transform={`rotate(-90 ${size / 2} ${size / 2})`}
      />
    </svg>
  );
}

function Donut({ days }: { days: DayTotal[] }) {
  const size = 110;
  const stroke = 10;
  const r = (size - stroke) / 2;
  const c = 2 * Math.PI * r;
  const total = Math.max(days.reduce((s, d) => s + d.total, 0), 1);
  let offset = 0;
  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`}>
      <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke="var(--ring-track)" strokeWidth={stroke} />
      {days.map((day, i) => {
        const sweep = (day.total / total) * c;
        const el = (
          <circle
            key={day.day}
            cx={size / 2}
            cy={size / 2}
            r={r}
            fill="none"
            stroke={WEEKDAY_COLORS[i % WEEKDAY_COLORS.length]}
            strokeWidth={stroke}
            strokeDasharray={`${sweep} ${c - sweep}`}
            strokeDashoffset={-offset}
            transform={`rotate(-90 ${size / 2} ${size / 2})`}
          />
        );
        offset += sweep;
        return el;
      })}
      <text x="50%" y="46%" textAnchor="middle" className="donut-total">{formatCompactTokens(total)}</text>
      <text x="50%" y="62%" textAnchor="middle" className="donut-label">7 DNI</text>
    </svg>
  );
}

const MODEL_RING_COLORS = ["var(--accent)", "var(--blue)", "var(--teal)", "var(--rose)"];

export default function Dashboard() {
  const [status, setStatus] = useState<Status | null>(null);

  useEffect(() => {
    let cancelled = false;
    const poll = async () => {
      try {
        const res = await fetch("/api/status");
        if (!res.ok) return;
        const data = (await res.json()) as Status;
        if (!cancelled) setStatus(data);
      } catch {
        // offline — keep last known status rather than flashing errors
      }
    };
    void poll();
    const id = setInterval(poll, 5000);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, []);

  const t = status?.tokens;
  const hw = status?.hardware;
  const costs = status?.costs;
  const hasCosts = costs?.nbpUsdRate != null && costs?.apiValueZl != null;

  return (
    <div id="dashboard">
      {/* Hero */}
      <div className="hero">
        <div className="hero-left">
          <div className="hero-hi">Witaj, Paweł!</div>
          <div className="status-line">
            <span className={`dot ${status?.gatewayAlive ? "alive" : ""}`} />
            <span>Hermes</span>
            <span className={`dot ${status?.ollamaAlive ? "alive" : ""}`} />
            <span>Ollama</span>
            {status?.activeModel && <span>· {status.activeModel}</span>}
            <span className="agenci">Agenci {status?.activeAgents ?? 0}</span>
          </div>
        </div>
        <div className="hero-right">
          <div className="dash-label">Tokeny 7 dni</div>
          <div className="hero-stat">{t ? formatCompactTokens(t.sevenDay) : "—"}</div>
          <div className="hero-version">{status?.appVersion ?? ""}</div>
        </div>
      </div>

      {/* Hardware strip */}
      <div className="hw-strip">
        <div className="hw-card">
          <div className="hw-label">CPU</div>
          <div className="hw-value">{hw?.cpuPercent != null ? `${plNumber(hw.cpuPercent, 0)}%` : "brak danych"}</div>
        </div>
        <div className="hw-card">
          <div className="hw-label">GPU</div>
          <div className="hw-value">{hw?.gpuPercent != null ? `${plNumber(hw.gpuPercent, 0)}%` : "brak danych"}</div>
        </div>
        <div className="hw-card">
          <div className="hw-label">RAM</div>
          <div className="hw-value">
            {hw?.ramUsedGB != null ? `${plNumber(hw.ramUsedGB, 1)}` : "—"}
            <span className="hw-unit">/{hw ? Math.round(hw.ramTotalGB) : "?"}G</span>
          </div>
        </div>
        <div className="hw-card">
          <div className="hw-label">SSD</div>
          <div className="hw-value">
            {hw?.ssdAvailableGB != null ? plNumber(hw.ssdAvailableGB, 0) : "—"}
            <span className="hw-unit">G wolne</span>
          </div>
        </div>
        <div className="hw-card">
          <div className="hw-label">Sieć</div>
          <div className="hw-value hw-net">
            ↓{hw?.netDownMBs != null ? plNumber(hw.netDownMBs, 1) : "—"} ↑{hw?.netUpMBs != null ? plNumber(hw.netUpMBs, 1) : "—"}
            <span className="hw-unit"> M/s</span>
          </div>
        </div>
      </div>

      {/* 02 TOKENY */}
      <div className="section">
        <div className="section-head"><span className="section-num">02</span><span>Tokeny</span><span className="rule" /></div>

        <div className="kpi-row">
          <div className="kpi">
            <div className="kpi-label">Dziś</div>
            <div className="kpi-value">{t?.today != null ? formatCompactTokens(t.today) : "—"}</div>
            <div className="kpi-sub">{trendText(t?.todayTrendPercent ?? null)}</div>
          </div>
          <div className="kpi">
            <div className="kpi-label">7 dni</div>
            <div className="kpi-value">{t ? formatCompactTokens(t.sevenDay) : "—"}</div>
            <div className="kpi-sub">{t ? `${formatCompactTokens(Math.round(t.sevenDay / 7))}/d` : "—"}</div>
          </div>
          <div className="kpi">
            <div className="kpi-label">Miesiąc</div>
            <div className="kpi-value">{t ? formatCompactTokens(t.month) : "—"}</div>
            <div className="kpi-sub">{trendText(t?.monthTrendPercent ?? null)}</div>
          </div>
          <div className="kpi">
            <div className="kpi-label">Od początku</div>
            <div className="kpi-value">{t ? formatCompactTokens(t.allTime) : "—"}</div>
            <div className="kpi-sub">total</div>
          </div>
        </div>

        <div className="tokeny-row">
          <div className="donut-col">
            <div className="mini-label">Ostatnie 7 dni</div>
            {status && status.last7Days.length > 0 ? (
              <div className="donut-wrap">
                <Donut days={status.last7Days} />
                <div className="donut-legend">
                  {status.last7Days.slice(-4).map((d) => {
                    const idx = status.last7Days.indexOf(d);
                    return (
                      <div className="legend-row" key={d.day}>
                        <span className="legend-dot" style={{ background: WEEKDAY_COLORS[idx % WEEKDAY_COLORS.length] }} />
                        <span className="legend-day">{weekdayAbbrev(d.day)}</span>
                        <span className="legend-val">{formatCompactTokens(d.total)}</span>
                      </div>
                    );
                  })}
                </div>
              </div>
            ) : (
              <div className="dim">brak danych</div>
            )}
          </div>

          <div className="costs-col">
            <div className="mini-label">Koszty · kurs NBP dziś</div>
            {hasCosts && costs ? (
              <>
                <div className="cost-row"><span>Zapłacone (flat)</span><span className="cost-val">{costs.paidZl} zł<span className="cost-sub"> /mc</span></span></div>
                <div className="cost-row"><span>Wartość wg cen API</span><span className="cost-val">{costs.apiValueZl} zł<span className="cost-sub"> ≈ {costs.apiValueEur} €</span></span></div>
                <div className="cost-divider" />
                <div className="cost-row"><span>Oszczędność</span><span className="cost-val cost-good">−{costs.savingsPercent ?? 0}%</span></div>
              </>
            ) : (
              <div className="dim">brak kursu NBP lub danych o zużyciu</div>
            )}
          </div>
        </div>

        <div className="model-share">
          <div className="mini-label">Udział modeli — 7 dni</div>
          {status && status.modelShare7d.length > 0 ? (
            <div className="rings-row">
              {status.modelShare7d.map((m, i) => {
                const totalShare = Math.max(status.modelShare7d.reduce((s, x) => s + x.total, 0), 1);
                const pct = Math.round((m.total / totalShare) * 100);
                return (
                  <div className="ring-col" key={m.model}>
                    <div className="ring-wrap">
                      <Ring percent={pct} color={MODEL_RING_COLORS[i % MODEL_RING_COLORS.length]} />
                      <span className="ring-pct">{pct}%</span>
                    </div>
                    <div className="ring-model">{m.model.toUpperCase()}</div>
                    <div className="ring-total">{formatCompactTokens(m.total)}</div>
                  </div>
                );
              })}
            </div>
          ) : (
            <div className="dim">brak danych</div>
          )}
        </div>
      </div>

      {/* 03 PROCESY */}
      <div className="section">
        <div className="section-head">
          <span className="section-num">03</span><span>Procesy</span><span className="rule" />
          <span className="proc-count">top {status?.processes.length ?? 0} · CPU</span>
        </div>
        {status && status.processes.length > 0 ? (
          <div className="proc-table">
            <div className="proc-header">
              <span className="proc-name">Nazwa</span>
              <span className="proc-pid">PID</span>
              <span className="proc-cpu">CPU</span>
              <span className="proc-ram">RAM</span>
            </div>
            {status.processes.map((p) => (
              <div className="proc-row" key={p.pid}>
                <span className="proc-name">{p.name}</span>
                <span className="proc-pid">{p.pid}</span>
                <span className={`proc-cpu ${p.cpuPercent >= 50 ? "danger" : p.cpuPercent >= 20 ? "accent" : ""}`}>{Math.round(p.cpuPercent)}%</span>
                <span className="proc-ram">{fmtBytes(p.ramMB)}</span>
              </div>
            ))}
          </div>
        ) : (
          <div className="dim">brak danych</div>
        )}
      </div>
    </div>
  );
}
