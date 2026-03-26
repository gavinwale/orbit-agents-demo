"""
reports/generator.py — Generate a post-simulation HTML report.

Call generate_html(data) where data is the dict from SimulationState.report_snapshot().
"""

import json
from collections import defaultdict
from datetime import datetime

ROLE_COLOR = {
    'trader_bull':     '#00ff88', 'trader_bear':    '#ff5555', 'trader_neutral':  '#4488ff',
    'panic_seller':    '#ff2200', 'momentum_trader':'#00ccff',
    'arb':             '#aa44ff', 'lp':             '#ffaa00',
    'oracle_proposer': '#00dddd', 'oracle_challenger':'#ff8800', 'oracle_voter':  '#ffdd00',
    'adversarial':     '#ff44aa', 'adversarial_drain':'#ff6688', 'adversarial_fuzzer':'#ff88aa',
}
ROLE_LABEL = {
    'trader_bull':    'Bull Trader',    'trader_bear':    'Bear Trader',
    'trader_neutral': 'Contrarian',     'panic_seller':   'Panic Seller',
    'momentum_trader':'Momentum Trader','arb':            'Arbitrageur',
    'lp':             'Market Maker (LP)',
    'oracle_proposer':'Oracle Proposer','oracle_challenger':'Oracle Challenger',
    'oracle_voter':   'Arbitration Voter',
    'adversarial':    'Exploit Researcher','adversarial_drain':'Token Drain Tester',
    'adversarial_fuzzer':'Edge Case Fuzzer',
}
ROLE_ORDER = [
    'trader_bull', 'trader_bear', 'trader_neutral', 'panic_seller', 'momentum_trader',
    'arb', 'lp',
    'oracle_proposer', 'oracle_challenger', 'oracle_voter',
    'adversarial', 'adversarial_drain', 'adversarial_fuzzer',
]
ADV_FINDINGS = {
    'oracle_voter': [
        ('Dispute vote (YES)', 'vote(disputeId, true) — registered arbitrator votes on active challenges'),
        ('Finalize resolution', 'finalizeResolution() after challenge window expires'),
        ('Arbitration result read', 'getArbitrationResult() + getFinalOutcome() — verifies outcome'),
    ],
    'adversarial': [
        ('Double-send bug', 'buyYes → compare received tokens vs quoted amount'),
        ('Re-entrancy probe', 'Rapid repeated buyYes calls in same cycle'),
        ('Integer overflow', 'Extreme amounts passed to buyYes / buyNo'),
    ],
    'adversarial_drain': [
        ('Router token drain', 'placeLimitBuyYes → withdrawLimitOrder → check residual balance leak'),
        ('Fee siphoning cycle', 'Repeated approve → limit → withdraw to accumulate residuals'),
    ],
    'adversarial_fuzzer': [
        ('Zero-amount trades', 'buyYes(0) and buyNo(0) — expects on-chain revert'),
        ('Overflow amounts', 'buyYes(2^256-1) — expects on-chain revert'),
        ('Invalid market ID', 'Operations on non-existent market IDs'),
        ('LP fee bug validation', 'getClaimableLpFees always returns 0 — confirmed bug (SCONE-02)'),
        ('Protocol fee lock', 'collectFees sends to dead addr — funds unreachable (SCONE-03)'),
    ],
}


def generate_html(data: dict) -> str:
    prices      = data.get("prices", [])
    agent_stats = data.get("agent_stats", {})
    stats       = data.get("stats", {})
    news_prices = data.get("news_prices", [])
    model       = data.get("model", "?")
    markets     = data.get("markets", [])
    sim_start   = data.get("sim_start", 0)
    sim_end     = data.get("sim_end", 0)

    duration_s   = int((sim_end or 0) - (sim_start or 0))
    duration_str = f"{duration_s // 60}m {duration_s % 60}s"
    completed_at = (datetime.fromtimestamp(sim_end).strftime("%Y-%m-%d %H:%M:%S")
                    if sim_end else "—")

    # ── Chart data (sample to max 400 points) ──────────────────────────────
    step     = max(1, len(prices) // 400)
    sampled  = prices[::step]
    labels   = [datetime.fromtimestamp(p["ts"]).strftime("%H:%M:%S") for p in sampled]
    yes_data = [round(p["price"], 2) for p in sampled]
    no_data  = [round(100 - p["price"], 2) for p in sampled]

    opening     = prices[0]["price"]  if prices else 50.0
    closing     = prices[-1]["price"] if prices else 50.0
    price_delta = closing - opening

    # ── News impact ────────────────────────────────────────────────────────
    news_impact = []
    for ne in news_prices:
        ts          = ne["ts"]
        before_pts  = [p for p in prices if p["ts"] <= ts]
        after_pts   = [p for p in prices if ts + 30 <= p["ts"] <= ts + 120]
        p_before    = round(before_pts[-1]["price"], 1) if before_pts else None
        p_after     = round(after_pts[-1]["price"],  1) if after_pts  else None
        delta       = round(p_after - p_before, 1) if (p_before is not None and p_after is not None) else None
        news_impact.append({**ne, "before": p_before, "after": p_after, "delta": delta})

    # ── Role aggregates ────────────────────────────────────────────────────
    role_agg = defaultdict(lambda: {"count": 0, "yes": 0, "no": 0,
                                    "limit": 0, "errors": 0, "turns": 0})
    for s in agent_stats.values():
        r = s.get("role", "?")
        role_agg[r]["count"]  += 1
        role_agg[r]["yes"]    += s.get("yes", 0)
        role_agg[r]["no"]     += s.get("no", 0)
        role_agg[r]["limit"]  += s.get("limit", 0)
        role_agg[r]["errors"] += s.get("errors", 0)
        role_agg[r]["turns"]  += s.get("turns", 0)

    # ── Totals ─────────────────────────────────────────────────────────────
    tr           = stats.get("trades", {})
    total_yes    = tr.get("YES", 0)
    total_no     = tr.get("NO", 0)
    total_limit  = tr.get("LIMIT", 0)
    total_trades = total_yes + total_no + total_limit
    total_errors = stats.get("errors", 0)
    total_agents = stats.get("agents_total", len(agent_stats))
    total_done   = stats.get("agents_done", 0)

    top10 = sorted(
        agent_stats.items(),
        key=lambda x: x[1].get("yes", 0) + x[1].get("no", 0) + x[1].get("limit", 0),
        reverse=True,
    )[:10]

    # ── News markers ───────────────────────────────────────────────────────
    ts_list    = [p["ts"] for p in sampled]
    news_marks = []
    for ne in news_prices:
        if ts_list:
            diffs = [abs(t - ne["ts"]) for t in ts_list]
            li    = diffs.index(min(diffs))
            news_marks.append({"labelIdx": li, "sentiment": ne.get("sentiment", "neutral")})

    # ── HTML fragments ─────────────────────────────────────────────────────
    sent_color = {"bullish": "#55ff88", "bearish": "#ff5555", "neutral": "#77bbff"}
    sent_icon  = {"bullish": "🟢",      "bearish": "🔴",       "neutral": "🟡"}

    news_html = ""
    for ne in news_impact:
        sc    = sent_color.get(ne.get("sentiment", "neutral"), "#8ba5c9")
        icon  = sent_icon.get(ne.get("sentiment", "neutral"),  "◆")
        b_s   = f"{ne['before']}%" if ne["before"] is not None else "—"
        a_s   = f"{ne['after']}%"  if ne["after"]  is not None else "—"
        d     = ne.get("delta")
        d_s   = (f"+{d}%" if d and d > 0 else f"{d}%") if d is not None else "—"
        d_col = "#55ff88" if (d or 0) > 0 else "#ff5555" if (d or 0) < 0 else "#8ba5c9"
        news_html += (
            f'<div style="border:1px solid {sc}33;border-left:4px solid {sc};'
            f'border-radius:4px;padding:12px 16px;margin-bottom:12px;background:{sc}08">'
            f'<div style="font-size:13px;font-weight:bold;color:{sc};margin-bottom:6px">{icon} {ne["msg"]}</div>'
            f'<div style="display:flex;gap:32px;font-size:12px">'
            f'<span style="color:#4a6a8a">Before: <b style="color:#8ba5c9">{b_s}</b></span>'
            f'<span style="color:#4a6a8a">After ~60s: <b style="color:#8ba5c9">{a_s}</b></span>'
            f'<span style="color:#4a6a8a">Δ YES%: <b style="color:{d_col}">{d_s}</b></span>'
            f'</div></div>'
        )

    role_rows = ""
    for role in ROLE_ORDER:
        agg = role_agg.get(role)
        if not agg or agg["count"] == 0:
            continue
        color = ROLE_COLOR.get(role, "#8ba5c9")
        label = ROLE_LABEL.get(role, role)
        total = agg["yes"] + agg["no"] + agg["limit"]
        avg_t = round(agg["turns"] / agg["count"], 1) if agg["count"] else 0
        role_rows += (
            f'<tr><td><span style="color:{color}">●</span> {label}</td>'
            f'<td style="text-align:center">{agg["count"]}</td>'
            f'<td style="text-align:center;color:#00ff88">{agg["yes"]}</td>'
            f'<td style="text-align:center;color:#ff5555">{agg["no"]}</td>'
            f'<td style="text-align:center;color:#aa88ff">{agg["limit"]}</td>'
            f'<td style="text-align:center;color:#ff8800">{agg["errors"]}</td>'
            f'<td style="text-align:center">{avg_t}</td>'
            f'<td style="text-align:center;font-weight:bold;color:#8ba5c9">{total}</td></tr>'
        )

    medals   = ["🥇", "🥈", "🥉"]
    top_rows = ""
    for rank, (idx, s) in enumerate(top10, 1):
        role  = s.get("role", "?")
        color = ROLE_COLOR.get(role, "#8ba5c9")
        label = ROLE_LABEL.get(role, role)
        total = s.get("yes", 0) + s.get("no", 0) + s.get("limit", 0)
        medal = medals[rank - 1] if rank <= 3 else f"#{rank}"
        top_rows += (
            f'<tr><td style="color:#8ba5c9">{medal}</td>'
            f'<td><span style="color:{color}">●</span> Agent #{idx}</td>'
            f'<td style="color:#4488aa">{label}</td>'
            f'<td style="text-align:center;color:#00ff88">{s.get("yes",0)}</td>'
            f'<td style="text-align:center;color:#ff5555">{s.get("no",0)}</td>'
            f'<td style="text-align:center;color:#aa88ff">{s.get("limit",0)}</td>'
            f'<td style="text-align:center;font-weight:bold;color:#8ba5c9">{total}</td></tr>'
        )

    adv_rows = ""
    for role in ['oracle_voter', 'adversarial', 'adversarial_drain', 'adversarial_fuzzer']:
        agg = role_agg.get(role)
        if not agg or agg["count"] == 0:
            continue
        for test_name, desc in ADV_FINDINGS.get(role, []):
            adv_rows += (
                f'<tr><td style="color:{ROLE_COLOR[role]}">{ROLE_LABEL[role]}</td>'
                f'<td style="color:#ff88aa">{test_name}</td>'
                f'<td style="color:#4a6a8a;font-size:11px">{desc}</td>'
                f'<td style="text-align:center;color:#ff8800">{agg["errors"]} reverts</td></tr>'
            )

    delta_col  = "#55ff88" if price_delta >= 0 else "#ff5555"
    delta_str  = f"+{price_delta:.1f}%" if price_delta >= 0 else f"{price_delta:.1f}%"
    market_q   = markets[0] if markets else "?"
    yes_pct    = round(total_yes / total_trades * 100) if total_trades else 0
    no_pct     = round(total_no  / total_trades * 100) if total_trades else 0
    consensus  = "Bullish" if yes_pct > 55 else "Bearish" if no_pct > 55 else "Uncertain"
    cons_col   = "#00ff88" if consensus == "Bullish" else "#ff5555" if consensus == "Bearish" else "#ffaa00"

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>◈ OrbitAgents — Report</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
<style>
*{{box-sizing:border-box;margin:0;padding:0}}
body{{background:#040810;color:#8ba5c9;font-family:'Courier New',monospace;padding:36px;max-width:1380px;margin:0 auto;line-height:1.6}}
h1{{font-size:20px;letter-spacing:4px;color:#00d4ff;margin-bottom:4px}}
.sub{{font-size:11px;color:#2a4060;margin-bottom:32px;letter-spacing:.5px}}
h2{{font-size:11px;letter-spacing:3px;color:#00d4ff55;text-transform:uppercase;margin:36px 0 14px;border-bottom:1px solid #0d1f3c;padding-bottom:7px}}
.cards{{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:12px;margin-bottom:8px}}
.card{{background:#050c1a;border:1px solid #0d1f3c;border-radius:6px;padding:14px 16px}}
.card .cv{{font-size:28px;font-weight:bold;margin-bottom:3px}}
.card .cl{{font-size:10px;color:#1e3550;text-transform:uppercase;letter-spacing:1px}}
.chartbox{{background:#050c1a;border:1px solid #0d1f3c;border-radius:6px;padding:16px;margin-bottom:8px;height:310px;position:relative}}
.chartbox canvas{{position:absolute;top:16px;left:16px;width:calc(100% - 32px)!important;height:calc(100% - 32px)!important}}
table{{width:100%;border-collapse:collapse;font-size:12px;margin-bottom:8px}}
th{{font-size:9px;letter-spacing:1px;color:#1e3550;text-transform:uppercase;padding:7px 10px;border-bottom:1px solid #0d1f3c;text-align:left}}
td{{padding:7px 10px;border-bottom:1px solid #060e1c;color:#4a6a8a}}
tr:hover td{{background:#050c18}}
.note{{font-size:11px;color:#2a4060;border:1px solid #0d1f3c;border-left:3px solid #ff44aa55;border-radius:4px;padding:12px 14px;margin-top:12px;line-height:1.8}}
.footer{{margin-top:40px;font-size:10px;color:#1a3050;text-align:center;border-top:1px solid #0d1f3c;padding-top:16px}}
</style>
</head>
<body>
<h1>◈ ORBITAGENTS — SIMULATION REPORT</h1>
<div class="sub">
  Completed: {completed_at} &nbsp;·&nbsp;
  Duration: {duration_str} &nbsp;·&nbsp;
  Model: {(model or '').split('/')[-1]} &nbsp;·&nbsp;
  Market: {market_q}
</div>

<h2>Summary</h2>
<div class="cards">
  <div class="card"><div class="cv" style="color:#00d4ff">{total_agents}</div><div class="cl">Agents</div></div>
  <div class="card"><div class="cv" style="color:#8ba5c9">{total_done}</div><div class="cl">Completed</div></div>
  <div class="card"><div class="cv" style="color:#8ba5c9">{total_trades}</div><div class="cl">Total Trades</div></div>
  <div class="card"><div class="cv" style="color:#00ff88">{total_yes}</div><div class="cl">YES Buys</div></div>
  <div class="card"><div class="cv" style="color:#ff5555">{total_no}</div><div class="cl">NO Buys</div></div>
  <div class="card"><div class="cv" style="color:#aa88ff">{total_limit}</div><div class="cl">Limit Orders</div></div>
  <div class="card"><div class="cv" style="color:{delta_col}">{delta_str}</div><div class="cl">Price Δ</div></div>
  <div class="card"><div class="cv" style="color:#8ba5c9">{closing:.1f}%</div><div class="cl">Final YES%</div></div>
  <div class="card"><div class="cv" style="color:{cons_col}">{consensus}</div><div class="cl">Market Verdict</div></div>
  <div class="card"><div class="cv" style="color:#ff8800">{total_errors}</div><div class="cl">Errors</div></div>
</div>

<h2>YES / NO Price Chart</h2>
<div class="chartbox"><canvas id="priceChart"></canvas></div>

<h2>News Impact Analysis</h2>
{news_html or '<div style="color:#1e3550;font-size:12px;padding:8px 0">No news events recorded.</div>'}

<h2>Role Breakdown</h2>
<table>
  <thead><tr>
    <th>Role</th><th>Agents</th>
    <th style="color:#00ff88">YES</th><th style="color:#ff5555">NO</th>
    <th style="color:#aa88ff">Limit</th><th style="color:#ff8800">Errors</th>
    <th>Avg Turns</th><th>Total Acts</th>
  </tr></thead>
  <tbody>{role_rows or '<tr><td colspan="8" style="color:#1e3550;text-align:center">No data.</td></tr>'}</tbody>
</table>

<h2>Top 10 Most Active Agents</h2>
<table>
  <thead><tr>
    <th>Rank</th><th>Agent</th><th>Role</th>
    <th style="color:#00ff88">YES</th><th style="color:#ff5555">NO</th>
    <th style="color:#aa88ff">Limit</th><th>Total</th>
  </tr></thead>
  <tbody>{top_rows or '<tr><td colspan="7" style="color:#1e3550;text-align:center">No trade data.</td></tr>'}</tbody>
</table>

<h2>Adversarial Security Test Coverage</h2>
<table>
  <thead><tr><th>Agent Type</th><th>Test</th><th>Description</th><th>On-chain Result</th></tr></thead>
  <tbody>{adv_rows or '<tr><td colspan="4" style="color:#1e3550;text-align:center">No adversarial agents ran.</td></tr>'}</tbody>
</table>
<div class="note">
  ⚠️ Confirmed SCONE audit findings probed by adversarial agents:<br>
  &nbsp;&nbsp;• <b style="color:#ff6688">SCONE-02 LP fee bug</b> — <code>getClaimableLpFees</code> always returns 0; fees accumulate but are permanently inaccessible to LPs.<br>
  &nbsp;&nbsp;• <b style="color:#ff6688">SCONE-03 Protocol fee lock</b> — <code>collectFees</code> sends funds to a dead/zero address; protocol revenue is permanently lost.<br>
  &nbsp;&nbsp;• <b style="color:#ff6688">Router token drain</b> — <code>withdrawLimitOrder</code> returns residual token balances that accumulate in the Router; an attacker can extract them via a sequence of limit orders.<br>
  Error/revert counts above reflect on-chain rejects encountered during adversarial probes.
</div>

<div class="footer">
  Generated by OrbitAgents &nbsp;·&nbsp; ◈ Orbit Protocol Simulation Framework &nbsp;·&nbsp; {completed_at}
</div>

<script>
(function() {{
  const labels    = {json.dumps(labels)};
  const yesData   = {json.dumps(yes_data)};
  const noData    = {json.dumps(no_data)};
  const newsMarks = {json.dumps(news_marks)};
  const sentColors = {{bullish:'#55ff88', bearish:'#ff5555', neutral:'#77bbff'}};

  const newsPlugin = {{
    id: 'newsMarks',
    afterDraw(chart) {{
      if (!newsMarks.length) return;
      const {{ctx: c, chartArea, scales}} = chart;
      if (!chartArea || !scales.x) return;
      c.save();
      for (const m of newsMarks) {{
        if (m.labelIdx >= chart.data.labels.length) continue;
        const xPx = scales.x.getPixelForValue(m.labelIdx);
        const col = sentColors[m.sentiment] || '#8ba5c9';
        c.strokeStyle = col; c.lineWidth = 1.5; c.setLineDash([3, 5]); c.globalAlpha = .8;
        c.beginPath(); c.moveTo(xPx, chartArea.top); c.lineTo(xPx, chartArea.bottom); c.stroke();
        c.setLineDash([]); c.globalAlpha = 1;
        c.fillStyle = col; c.font = 'bold 11px Courier New';
        const icon = m.sentiment === 'bullish' ? '▲' : m.sentiment === 'bearish' ? '▼' : '◆';
        c.fillText(icon, xPx - 5, chartArea.top + 14);
      }}
      c.restore();
    }}
  }};

  new Chart(document.getElementById('priceChart').getContext('2d'), {{
    type: 'line',
    plugins: [newsPlugin],
    data: {{
      labels,
      datasets: [
        {{label:'YES %', data:yesData, borderColor:'#00ff88', backgroundColor:'rgba(0,255,136,0.07)',
          fill:true, tension:.3, pointRadius:0, borderWidth:2}},
        {{label:'NO %',  data:noData,  borderColor:'#ff5555', backgroundColor:'rgba(255,85,85,0.05)',
          fill:true, tension:.3, pointRadius:0, borderWidth:1.5, borderDash:[4,3]}},
        {{label:'50%',   data:labels.map(()=>50), borderColor:'#1a3050',
          fill:false, tension:0, pointRadius:0, borderWidth:1, borderDash:[2,6]}},
      ]
    }},
    options: {{
      responsive:true, maintainAspectRatio:false, animation:false,
      plugins: {{
        legend: {{labels: {{color:'#4a6a8a', font:{{family:'Courier New',size:10}}}}}},
        tooltip: {{
          backgroundColor:'#08152aee', borderColor:'#1a3a5a', borderWidth:1,
          titleColor:'#8ba5c9', bodyColor:'#4a7090',
          titleFont:{{family:'Courier New',size:10}}, bodyFont:{{family:'Courier New',size:11}},
          callbacks: {{label(ctx){{ return ` ${{ctx.dataset.label}}: ${{ctx.parsed.y?.toFixed(1)}}%`; }}}}
        }}
      }},
      scales: {{
        x: {{ticks:{{color:'#1a3050',font:{{size:9,family:'Courier New'}},maxTicksLimit:12,maxRotation:0}},
             grid:{{color:'#0a1525'}},border:{{color:'#0d1f3c'}}}},
        y: {{min:0,max:100,
             ticks:{{color:'#1a3050',font:{{size:9,family:'Courier New'}},callback:v=>v+'%',stepSize:25}},
             grid:{{color:'#0a1525'}},border:{{color:'#0d1f3c'}}}}
      }}
    }}
  }});
}})();
</script>
</body>
</html>"""
