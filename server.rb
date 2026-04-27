#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# ANCO Full-Stack Server — WEBrick + JSON API
# Pure Ruby stdlib, zero external gems required
# ============================================================

require "webrick"
require "json"
require "erb"
require_relative "anco_core"
require "securerandom"

# ── Live demo cache instance ─────────────────────────────────
$live_cache = ANCO::AdaptiveCache.new(capacity: 64)
$run_history = []
$tick = 0

# Pre-populate with some data
20.times { |i| $live_cache.set("demo_key_#{i}", "value_#{i * 100}") }

# ── Helpers ──────────────────────────────────────────────────
module APIHelpers
  def self.json_response(res, data, status: 200)
    res.status = status
    res["Content-Type"]  = "application/json"
    res["Access-Control-Allow-Origin"] = "*"
    res.body = JSON.generate(data)
  end

  def self.run_benchmark(ops: 1000, capacity: 64)
    results = {}
    ANCO::Benchmarker::WORKLOADS.each do |wl|
      cache = ANCO::AdaptiveCache.new(capacity: capacity)
      trace = ANCO::Benchmarker.generate_trace(wl, ops)
      t0 = Time.now
      trace.each do |op, key, val|
        op == :get ? cache.get(key) : cache.set(key, val)
      end
      elapsed = ((Time.now - t0) * 1000).round(2)
      d = cache.diagnostics
      results[wl] = d.merge(elapsed_ms: elapsed)
    end
    results
  end
end

# ── Servlet: Static HTML dashboard ───────────────────────────
class DashboardServlet < WEBrick::HTTPServlet::AbstractServlet
  def do_GET(req, res)
    res.status = 200
    res["Content-Type"] = "text/html; charset=utf-8"
    res.body = DASHBOARD_HTML
  end
end

# ── Servlet: GET /api/benchmark ───────────────────────────────
class BenchmarkServlet < WEBrick::HTTPServlet::AbstractServlet
  def do_GET(req, res)
    ops      = (req.query["ops"]      || "800").to_i.clamp(100, 5000)
    capacity = (req.query["capacity"] || "64").to_i.clamp(8, 512)

    results = APIHelpers.run_benchmark(ops: ops, capacity: capacity)

    payload = {
      timestamp: Time.now.iso8601,
      ops: ops,
      capacity: capacity,
      results: results.transform_keys(&:to_s).transform_values { |v|
        v.transform_keys(&:to_s)
      }
    }

    $run_history.unshift({ ran_at: Time.now.strftime("%H:%M:%S"), ops: ops, capacity: capacity,
                           best_workload: results.max_by { |_, d| d[:hit_rate] }&.first.to_s,
                           best_hit_rate: results.values.map { |d| d[:hit_rate] }.max&.round(4) })
    $run_history = $run_history.first(10)

    APIHelpers.json_response(res, payload)
  end
end

# ── Servlet: POST /api/cache/set ──────────────────────────────
class CacheSetServlet < WEBrick::HTTPServlet::AbstractServlet
  def do_POST(req, res)
    body = JSON.parse(req.body || "{}")
    key  = body["key"].to_s.strip
    val  = body["value"].to_s.strip
    return APIHelpers.json_response(res, { error: "key required" }, status: 400) if key.empty?

    $live_cache.set(key, val)
    APIHelpers.json_response(res, {
      ok: true, key: key,
      cache_size: $live_cache.size,
      hit_rate: $live_cache.hit_rate.round(4)
    })
  end
end

# ── Servlet: GET /api/cache/get ───────────────────────────────
class CacheGetServlet < WEBrick::HTTPServlet::AbstractServlet
  def do_GET(req, res)
    key = (req.query["key"] || "").strip
    return APIHelpers.json_response(res, { error: "key required" }, status: 400) if key.empty?

    val = $live_cache.get(key)
    APIHelpers.json_response(res, {
      key: key,
      value: val,
      hit: !val.nil?,
      hit_rate: $live_cache.hit_rate.round(4),
      cache_size: $live_cache.size,
      diagnostics: $live_cache.diagnostics.transform_keys(&:to_s)
    })
  end
end

# ── Servlet: GET /api/status ──────────────────────────────────
class StatusServlet < WEBrick::HTTPServlet::AbstractServlet
  def do_GET(req, res)
    APIHelpers.json_response(res, {
      status: "running",
      ruby_version: RUBY_VERSION,
      anco_version: ANCO::VERSION,
      live_cache: $live_cache.diagnostics.transform_keys(&:to_s),
      warm_entries: $live_cache.warm_entries(5),
      run_history: $run_history
    })
  end
end

# ── Dashboard HTML (inline, zero file dependencies) ──────────
DASHBOARD_HTML = <<~'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1.0"/>
<title>ANCO — Adaptive Neural Cache Optimizer</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Space+Mono:wght@400;700&family=Syne:wght@400;700;800&display=swap" rel="stylesheet">
<style>
  :root {
    --bg: #04060f;
    --surface: #080d1e;
    --card: #0c1228;
    --border: #1a2448;
    --accent: #00f5c4;
    --accent2: #ff6b35;
    --accent3: #a78bfa;
    --text: #e2e8f0;
    --muted: #64748b;
    --hit: #00f5c4;
    --miss: #ff6b35;
    --font-mono: 'Space Mono', monospace;
    --font-display: 'Syne', sans-serif;
  }

  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  body {
    background: var(--bg);
    color: var(--text);
    font-family: var(--font-display);
    min-height: 100vh;
    overflow-x: hidden;
  }

  /* Animated grid background */
  body::before {
    content: '';
    position: fixed; inset: 0;
    background-image:
      linear-gradient(rgba(0,245,196,0.03) 1px, transparent 1px),
      linear-gradient(90deg, rgba(0,245,196,0.03) 1px, transparent 1px);
    background-size: 40px 40px;
    pointer-events: none;
    z-index: 0;
  }

  /* Glowing orbs */
  body::after {
    content: '';
    position: fixed;
    top: -200px; left: -200px;
    width: 600px; height: 600px;
    background: radial-gradient(circle, rgba(0,245,196,0.06) 0%, transparent 70%);
    pointer-events: none;
    z-index: 0;
    animation: drift 12s ease-in-out infinite alternate;
  }

  @keyframes drift {
    from { transform: translate(0,0); }
    to   { transform: translate(300px, 200px); }
  }

  .container { max-width: 1300px; margin: 0 auto; padding: 0 24px; position: relative; z-index: 1; }

  /* ── Header ── */
  header {
    padding: 32px 0 24px;
    border-bottom: 1px solid var(--border);
    margin-bottom: 36px;
    display: flex; align-items: center; justify-content: space-between;
    flex-wrap: wrap; gap: 16px;
  }

  .logo-group { display: flex; align-items: baseline; gap: 16px; }

  h1 {
    font-size: clamp(2rem, 5vw, 3.2rem);
    font-weight: 800;
    letter-spacing: -1px;
    background: linear-gradient(135deg, var(--accent) 0%, var(--accent3) 100%);
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
    background-clip: text;
  }

  .version-badge {
    font-family: var(--font-mono);
    font-size: 0.7rem;
    padding: 3px 10px;
    border: 1px solid var(--accent);
    color: var(--accent);
    border-radius: 20px;
    letter-spacing: 1px;
  }

  .subtitle {
    font-size: 0.85rem;
    color: var(--muted);
    font-family: var(--font-mono);
    letter-spacing: 0.5px;
  }

  .status-dot {
    display: inline-block; width: 8px; height: 8px;
    background: var(--accent); border-radius: 50%;
    margin-right: 8px;
    animation: pulse 2s infinite;
  }
  @keyframes pulse {
    0%,100% { opacity: 1; box-shadow: 0 0 0 0 rgba(0,245,196,0.4); }
    50%      { opacity: 0.7; box-shadow: 0 0 0 6px rgba(0,245,196,0); }
  }

  /* ── Grid Layout ── */
  .grid-main  { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 20px; margin-bottom: 24px; }
  .grid-bench { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin-bottom: 24px; }
  .grid-bot   { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin-bottom: 40px; }

  @media (max-width: 900px) {
    .grid-main  { grid-template-columns: 1fr; }
    .grid-bench { grid-template-columns: 1fr; }
    .grid-bot   { grid-template-columns: 1fr; }
  }

  /* ── Cards ── */
  .card {
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 16px;
    padding: 24px;
    position: relative;
    overflow: hidden;
    transition: border-color 0.3s, transform 0.3s;
  }
  .card:hover { border-color: rgba(0,245,196,0.3); transform: translateY(-2px); }
  .card::before {
    content: '';
    position: absolute; top: 0; left: 0; right: 0; height: 1px;
    background: linear-gradient(90deg, transparent, var(--accent), transparent);
    opacity: 0.4;
  }

  .card-label {
    font-family: var(--font-mono);
    font-size: 0.65rem;
    letter-spacing: 2px;
    color: var(--muted);
    text-transform: uppercase;
    margin-bottom: 12px;
  }

  .card-value {
    font-size: 2.4rem;
    font-weight: 800;
    line-height: 1;
    margin-bottom: 6px;
  }

  .card-sub { font-size: 0.78rem; color: var(--muted); font-family: var(--font-mono); }

  .accent-green { color: var(--accent); }
  .accent-orange { color: var(--accent2); }
  .accent-purple { color: var(--accent3); }

  /* ── Section Titles ── */
  .section-title {
    font-size: 1.1rem;
    font-weight: 700;
    color: var(--text);
    margin-bottom: 20px;
    display: flex; align-items: center; gap: 10px;
  }
  .section-title::after {
    content: '';
    flex: 1; height: 1px;
    background: linear-gradient(90deg, var(--border), transparent);
  }

  /* ── Benchmark Panel ── */
  .bench-card { grid-column: span 2; }

  .bench-controls {
    display: flex; gap: 12px; align-items: flex-end;
    flex-wrap: wrap; margin-bottom: 28px;
  }

  .input-group { display: flex; flex-direction: column; gap: 6px; }
  .input-group label { font-size: 0.7rem; color: var(--muted); font-family: var(--font-mono); letter-spacing: 1px; }

  input[type="range"] {
    -webkit-appearance: none;
    width: 160px; height: 4px;
    background: var(--border);
    border-radius: 2px; outline: none; cursor: pointer;
  }
  input[type="range"]::-webkit-slider-thumb {
    -webkit-appearance: none;
    width: 16px; height: 16px;
    background: var(--accent);
    border-radius: 50%;
    cursor: pointer;
  }

  .range-val { font-family: var(--font-mono); font-size: 0.75rem; color: var(--accent); }

  button {
    font-family: var(--font-display);
    font-weight: 700;
    font-size: 0.85rem;
    padding: 10px 24px;
    border: none; border-radius: 8px;
    cursor: pointer;
    transition: all 0.2s;
    letter-spacing: 0.5px;
  }

  .btn-run {
    background: var(--accent);
    color: #000;
  }
  .btn-run:hover { background: #00d4a8; transform: scale(1.04); }
  .btn-run:disabled { opacity: 0.5; cursor: not-allowed; transform: none; }

  .btn-ghost {
    background: transparent;
    color: var(--text);
    border: 1px solid var(--border);
  }
  .btn-ghost:hover { border-color: var(--accent); color: var(--accent); }

  /* ── Workload Bars ── */
  .workload-grid { display: flex; flex-direction: column; gap: 14px; }

  .workload-row {
    display: grid;
    grid-template-columns: 130px 1fr 60px;
    align-items: center; gap: 12px;
    opacity: 0; animation: fadeIn 0.5s forwards;
  }
  @keyframes fadeIn { to { opacity: 1; } }

  .wl-name { font-family: var(--font-mono); font-size: 0.72rem; color: var(--muted); }

  .bar-track { height: 10px; background: var(--border); border-radius: 5px; overflow: hidden; }

  .bar-fill {
    height: 100%; border-radius: 5px;
    transition: width 1.2s cubic-bezier(0.16,1,0.3,1);
    width: 0%;
  }

  .bar-pct { font-family: var(--font-mono); font-size: 0.75rem; text-align: right; }

  /* ── Live Cache Panel ── */
  .cache-input-row { display: flex; gap: 10px; margin-bottom: 20px; flex-wrap: wrap; }

  .text-input {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 9px 14px;
    color: var(--text);
    font-family: var(--font-mono);
    font-size: 0.8rem;
    outline: none;
    transition: border-color 0.2s;
    flex: 1; min-width: 80px;
  }
  .text-input:focus { border-color: var(--accent); }
  .text-input::placeholder { color: var(--muted); }

  .cache-log {
    height: 200px;
    overflow-y: auto;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 12px;
    font-family: var(--font-mono);
    font-size: 0.72rem;
    line-height: 1.8;
  }
  .cache-log::-webkit-scrollbar { width: 4px; }
  .cache-log::-webkit-scrollbar-track { background: transparent; }
  .cache-log::-webkit-scrollbar-thumb { background: var(--border); border-radius: 2px; }

  .log-hit  { color: var(--accent); }
  .log-miss { color: var(--accent2); }
  .log-set  { color: var(--accent3); }
  .log-ts   { color: var(--muted); margin-right: 8px; }

  /* ── Agent Stats ── */
  .agent-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }

  .stat-row {
    display: flex; justify-content: space-between; align-items: center;
    padding: 10px 0;
    border-bottom: 1px solid var(--border);
  }
  .stat-row:last-child { border: none; }
  .stat-key { font-family: var(--font-mono); font-size: 0.7rem; color: var(--muted); }
  .stat-val { font-family: var(--font-mono); font-size: 0.8rem; color: var(--accent); font-weight: 700; }

  /* ── Bandit Policy Chart ── */
  .policy-bars { display: flex; flex-direction: column; gap: 10px; }
  .policy-row { display: grid; grid-template-columns: 90px 1fr 50px; align-items: center; gap: 10px; }
  .policy-name { font-family: var(--font-mono); font-size: 0.68rem; color: var(--muted); }
  .policy-fill {
    height: 8px; background: var(--border); border-radius: 4px; overflow: hidden;
  }
  .policy-fill-inner { height: 100%; border-radius: 4px; background: var(--accent3); transition: width 0.8s ease; }
  .policy-pct { font-family: var(--font-mono); font-size: 0.68rem; color: var(--accent3); }

  /* ── History Table ── */
  .history-table { width: 100%; border-collapse: collapse; font-family: var(--font-mono); font-size: 0.72rem; }
  .history-table th {
    text-align: left; padding: 8px 12px;
    color: var(--muted); border-bottom: 1px solid var(--border);
    letter-spacing: 1px; font-size: 0.65rem; text-transform: uppercase;
  }
  .history-table td { padding: 9px 12px; border-bottom: 1px solid rgba(26,36,72,0.5); }
  .history-table tr:hover td { background: rgba(0,245,196,0.03); }

  /* ── Loading spinner ── */
  .spinner {
    display: inline-block; width: 16px; height: 16px;
    border: 2px solid rgba(0,245,196,0.3);
    border-top-color: var(--accent);
    border-radius: 50%;
    animation: spin 0.7s linear infinite;
    margin-right: 8px; vertical-align: middle;
  }
  @keyframes spin { to { transform: rotate(360deg); } }

  .hidden { display: none; }

  /* ── Footer ── */
  footer {
    text-align: center; padding: 32px 0;
    border-top: 1px solid var(--border);
    font-family: var(--font-mono);
    font-size: 0.7rem; color: var(--muted);
  }
  footer span { color: var(--accent); }

  /* ── Toast ── */
  .toast {
    position: fixed; bottom: 24px; right: 24px;
    background: var(--card); border: 1px solid var(--accent);
    border-radius: 10px; padding: 12px 20px;
    font-family: var(--font-mono); font-size: 0.78rem;
    color: var(--accent); z-index: 999;
    transform: translateY(80px); opacity: 0;
    transition: all 0.35s cubic-bezier(0.16,1,0.3,1);
    pointer-events: none;
  }
  .toast.show { transform: translateY(0); opacity: 1; }
</style>
</head>
<body>
<div class="container">

  <!-- ── Header ── -->
  <header>
    <div>
      <div class="logo-group">
        <h1>ANCO</h1>
        <span class="version-badge">v1.0.0</span>
      </div>
      <p class="subtitle"><span class="status-dot"></span>Adaptive Neural Cache Optimizer · Ruby 3.2 · Research Dashboard</p>
    </div>
    <button class="btn-ghost" onclick="loadStatus()">↻ Refresh Status</button>
  </header>

  <!-- ── Live KPIs ── -->
  <div class="grid-main" id="kpi-grid">
    <div class="card">
      <div class="card-label">Live Hit Rate</div>
      <div class="card-value accent-green" id="kpi-hitrate">—</div>
      <div class="card-sub" id="kpi-hits-misses">Loading...</div>
    </div>
    <div class="card">
      <div class="card-label">Cache Entries</div>
      <div class="card-value accent-purple" id="kpi-size">—</div>
      <div class="card-sub" id="kpi-capacity">capacity: —</div>
    </div>
    <div class="card">
      <div class="card-label">Workload Pattern</div>
      <div class="card-value accent-orange" id="kpi-pattern" style="font-size:1.4rem; padding-top:8px;">—</div>
      <div class="card-sub" id="kpi-entropy">entropy: — bits</div>
    </div>
  </div>

  <!-- ── Benchmark + Agent ── -->
  <div class="grid-bench">

    <!-- Benchmark Panel -->
    <div class="card bench-card" style="grid-column: span 1">
      <div class="section-title">⚡ Benchmark Runner</div>
      <div class="bench-controls">
        <div class="input-group">
          <label>OPS: <span class="range-val" id="ops-val">800</span></label>
          <input type="range" id="ops-range" min="100" max="3000" step="100" value="800"
                 oninput="document.getElementById('ops-val').textContent=this.value">
        </div>
        <div class="input-group">
          <label>CAPACITY: <span class="range-val" id="cap-val">64</span></label>
          <input type="range" id="cap-range" min="8" max="256" step="8" value="64"
                 oninput="document.getElementById('cap-val').textContent=this.value">
        </div>
        <button class="btn-run" id="run-btn" onclick="runBenchmark()">▶ Run</button>
      </div>
      <div class="workload-grid" id="workload-bars">
        <div style="color:var(--muted); font-family:var(--font-mono); font-size:0.75rem;">
          Click "Run" to execute benchmarks →
        </div>
      </div>
    </div>

    <!-- Agent Stats -->
    <div class="card">
      <div class="section-title">🤖 Q-Learning Agent</div>
      <div id="agent-stats">
        <div class="stat-row"><span class="stat-key">Q-Table States</span><span class="stat-val" id="ag-qtable">—</span></div>
        <div class="stat-row"><span class="stat-key">Total Updates</span><span class="stat-val" id="ag-updates">—</span></div>
        <div class="stat-row"><span class="stat-key">Avg TD Error</span><span class="stat-val" id="ag-tderr">—</span></div>
        <div class="stat-row"><span class="stat-key">Learning Rate α</span><span class="stat-val">0.15</span></div>
        <div class="stat-row"><span class="stat-key">Discount γ</span><span class="stat-val">0.90</span></div>
        <div class="stat-row"><span class="stat-key">Exploration ε</span><span class="stat-val">0.10</span></div>
        <div class="stat-row"><span class="stat-key">Total Evictions</span><span class="stat-val" id="ag-evict">—</span></div>
        <div class="stat-row"><span class="stat-key">Prefetch Hits</span><span class="stat-val" id="ag-prefetch">—</span></div>
      </div>
    </div>
  </div>

  <!-- ── Live Cache + Bandit ── -->
  <div class="grid-bot">

    <!-- Live Cache Interactive -->
    <div class="card">
      <div class="section-title">🗄️ Live Cache — Try It</div>
      <div class="cache-input-row">
        <input class="text-input" id="set-key" placeholder="key" maxlength="20"/>
        <input class="text-input" id="set-val" placeholder="value" maxlength="50"/>
        <button class="btn-run" onclick="doSet()">SET</button>
      </div>
      <div class="cache-input-row" style="margin-bottom:14px">
        <input class="text-input" id="get-key" placeholder="key to GET" maxlength="20"/>
        <button class="btn-ghost" onclick="doGet()">GET</button>
      </div>
      <div class="cache-log" id="cache-log">
        <span style="color:var(--muted)">// Cache operations appear here...</span>
      </div>
    </div>

    <!-- Bandit Policy Stats -->
    <div class="card">
      <div class="section-title">🎰 UCB1 Bandit — Policy Selector</div>
      <div class="policy-bars" id="policy-bars">
        <div style="color:var(--muted); font-family:var(--font-mono); font-size:0.75rem;">Run benchmark to see policy selection →</div>
      </div>
      <div style="margin-top: 24px;">
        <div class="section-title" style="font-size:0.9rem;">📜 Run History</div>
        <table class="history-table">
          <thead><tr><th>Time</th><th>Ops</th><th>Best Workload</th><th>Hit Rate</th></tr></thead>
          <tbody id="history-tbody">
            <tr><td colspan="4" style="color:var(--muted); text-align:center">No runs yet</td></tr>
          </tbody>
        </table>
      </div>
    </div>
  </div>

</div><!-- /container -->

<!-- Toast -->
<div class="toast" id="toast"></div>

<footer>
  <div class="container">
    <p>ANCO · <span>Adaptive Neural Cache Optimizer</span> · Developed by Yash Jain </p>
    <p style="margin-top:6px">Q-Learning · UCB1 Multi-Armed Bandit · Fiber Prefetching · Workload Fingerprinting</p>
  </div>
</footer>

<script>
const API = '';  // same origin

// ── Toast ─────────────────────────────────────────────────────
function showToast(msg) {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.classList.add('show');
  setTimeout(() => t.classList.remove('show'), 2800);
}

// ── Load Status ───────────────────────────────────────────────
async function loadStatus() {
  try {
    const r = await fetch(API + '/api/status');
    const d = await r.json();
    const c = d.live_cache;

    document.getElementById('kpi-hitrate').textContent =
      ((c.hit_rate || 0) * 100).toFixed(1) + '%';
    document.getElementById('kpi-hits-misses').textContent =
      `hits: ${c.hits} · misses: ${c.misses}`;
    document.getElementById('kpi-size').textContent = c.cache_size;
    document.getElementById('kpi-capacity').textContent = `capacity: ${c.capacity}`;
    document.getElementById('kpi-pattern').textContent =
      (c.workload_pattern || 'unknown').replace('_', ' ').toUpperCase();
    document.getElementById('kpi-entropy').textContent =
      `entropy: ${c.access_entropy} bits`;

    document.getElementById('ag-qtable').textContent  = c.agent?.q_table_size ?? '—';
    document.getElementById('ag-updates').textContent = c.agent?.total_updates ?? '—';
    document.getElementById('ag-tderr').textContent   = c.avg_td_error ?? '—';
    document.getElementById('ag-evict').textContent   = c.evictions ?? '—';
    document.getElementById('ag-prefetch').textContent = c.prefetch_hits ?? '—';

    // History
    if (d.run_history && d.run_history.length > 0) {
      const tbody = document.getElementById('history-tbody');
      tbody.innerHTML = d.run_history.map(h => `
        <tr>
          <td>${h.ran_at}</td>
          <td>${h.ops}</td>
          <td style="color:var(--accent)">${h.best_workload}</td>
          <td style="color:var(--accent)">${((h.best_hit_rate||0)*100).toFixed(1)}%</td>
        </tr>`).join('');
    }
  } catch(e) {
    console.error('Status fetch failed:', e);
  }
}

// ── Run Benchmark ─────────────────────────────────────────────
async function runBenchmark() {
  const btn = document.getElementById('run-btn');
  const ops = document.getElementById('ops-range').value;
  const cap = document.getElementById('cap-range').value;

  btn.disabled = true;
  btn.innerHTML = '<span class="spinner"></span>Running...';

  const container = document.getElementById('workload-bars');
  container.innerHTML = '<div style="color:var(--muted);font-family:var(--font-mono);font-size:0.75rem"><span class="spinner"></span>Benchmarking all workloads...</div>';

  try {
    const r   = await fetch(`${API}/api/benchmark?ops=${ops}&capacity=${cap}`);
    const d   = await r.json();
    const res = d.results;

    const colors = {
      zipfian:          '#00f5c4',
      sequential:       '#a78bfa',
      random:           '#fb923c',
      temporal_locality:'#38bdf8',
      mixed:            '#f472b6'
    };

    // Sort by hit rate
    const sorted = Object.entries(res).sort((a,b) => b[1].hit_rate - a[1].hit_rate);

    container.innerHTML = sorted.map(([wl, data], i) => {
      const pct = ((data.hit_rate || 0) * 100).toFixed(1);
      const col = colors[wl] || '#fff';
      return `<div class="workload-row" style="animation-delay:${i*0.1}s">
        <span class="wl-name">${wl.replace('_',' ')}</span>
        <div class="bar-track">
          <div class="bar-fill" id="bar-${wl}"
               style="background:${col}; width:0%"
               data-pct="${pct}">
          </div>
        </div>
        <span class="bar-pct" style="color:${col}">${pct}%</span>
      </div>`;
    }).join('');

    // Animate bars after DOM settles
    setTimeout(() => {
      sorted.forEach(([wl]) => {
        const el = document.getElementById(`bar-${wl}`);
        if (el) el.style.width = el.dataset.pct + '%';
      });
    }, 50);

    // Render bandit stats from first result with bandit data
    const anyResult = Object.values(res)[0];
    if (anyResult?.bandit_stats) {
      renderBanditStats(anyResult.bandit_stats);
    }

    // Refresh KPIs
    await loadStatus();
    showToast(`✓ Benchmark complete · ${ops} ops`);

  } catch(e) {
    container.innerHTML = `<span style="color:var(--miss)">Error: ${e.message}</span>`;
  } finally {
    btn.disabled = false;
    btn.innerHTML = '▶ Run';
  }
}

function renderBanditStats(stats) {
  const maxPulls = Math.max(...stats.map(s => s.pulls), 1);
  const container = document.getElementById('policy-bars');
  container.innerHTML = stats.map(s => {
    const pct = ((s.pulls / maxPulls) * 100).toFixed(0);
    return `<div class="policy-row">
      <span class="policy-name">${s.policy}</span>
      <div class="policy-fill">
        <div class="policy-fill-inner" style="width:${pct}%"></div>
      </div>
      <span class="policy-pct">${s.avg_reward.toFixed(3)}</span>
    </div>`;
  }).join('');
}

// ── Live Cache ops ────────────────────────────────────────────
function appendLog(html) {
  const log = document.getElementById('cache-log');
  const ts = new Date().toLocaleTimeString('en',{hour12:false});
  log.innerHTML += `<div><span class="log-ts">${ts}</span>${html}</div>`;
  log.scrollTop = log.scrollHeight;
}

async function doSet() {
  const key = document.getElementById('set-key').value.trim();
  const val = document.getElementById('set-val').value.trim();
  if (!key) return showToast('⚠ Enter a key');
  try {
    const r = await fetch(API + '/api/cache/set', {
      method: 'POST',
      headers: {'Content-Type':'application/json'},
      body: JSON.stringify({key, value: val})
    });
    const d = await r.json();
    appendLog(`<span class="log-set">SET</span> <b>${key}</b> = "${val}" · size=${d.cache_size}`);
    document.getElementById('set-key').value = '';
    document.getElementById('set-val').value = '';
    loadStatus();
  } catch(e) { appendLog(`<span class="log-miss">ERROR</span> ${e.message}`); }
}

async function doGet() {
  const key = document.getElementById('get-key').value.trim();
  if (!key) return showToast('⚠ Enter a key');
  try {
    const r = await fetch(`${API}/api/cache/get?key=${encodeURIComponent(key)}`);
    const d = await r.json();
    if (d.hit) {
      appendLog(`<span class="log-hit">HIT</span>  <b>${key}</b> → "${d.value}" · hit_rate=${(d.hit_rate*100).toFixed(1)}%`);
    } else {
      appendLog(`<span class="log-miss">MISS</span> <b>${key}</b> → not in cache`);
    }
    loadStatus();
  } catch(e) { appendLog(`<span class="log-miss">ERROR</span> ${e.message}`); }
}

// Enter key support
document.addEventListener('keydown', e => {
  if (e.key === 'Enter') {
    if (document.activeElement.id === 'get-key') doGet();
    if (document.activeElement.id === 'set-val') doSet();
  }
});

// ── Boot ─────────────────────────────────────────────────────
loadStatus();
setInterval(loadStatus, 5000);  // auto-refresh every 5s
</script>
</body>
</html>
HTML

# ── Start Server ─────────────────────────────────────────────
PORT = (ENV["PORT"] || 4567).to_i

server = WEBrick::HTTPServer.new(
  Port:            PORT,
  DocumentRoot:    __dir__,
  Logger:          WEBrick::Log.new($stdout, WEBrick::Log::INFO),
  AccessLog:       []
)

server.mount "/",               DashboardServlet
server.mount "/api/benchmark",  BenchmarkServlet
server.mount "/api/cache/set",  CacheSetServlet
server.mount "/api/cache/get",  CacheGetServlet
server.mount "/api/status",     StatusServlet

trap("INT")  { server.shutdown }
trap("TERM") { server.shutdown }

puts ""
puts "╔══════════════════════════════════════════════════╗"
puts "║  ANCO Research Dashboard                         ║"
puts "║  → http://localhost:#{PORT}                         ║"
puts "║  Press Ctrl+C to stop                            ║"
puts "╚══════════════════════════════════════════════════╝"
puts ""

server.start
