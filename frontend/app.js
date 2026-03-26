/* OrbitAgents Dashboard — SSE client + Chart.js rendering */

// ── State ───────────────────────────────────────────────────────────────────
let evtSource = null;
let chart = null;
let simStartTime = 0;
let simDuration = 300;
let timerInterval = null;

const stats = { yes: 0, no: 0, limit: 0, errors: 0, agentsDone: 0, agentsTotal: 0 };

// ── Chart setup ─────────────────────────────────────────────────────────────
function initChart() {
  const ctx = document.getElementById('priceChart').getContext('2d');
  chart = new Chart(ctx, {
    type: 'line',
    data: {
      labels: [],
      datasets: [{
        label: 'YES Probability %',
        data: [],
        borderColor: '#00d4ff',
        backgroundColor: 'rgba(0, 212, 255, 0.05)',
        borderWidth: 2,
        pointRadius: 0,
        tension: 0.3,
        fill: true,
      }],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      animation: { duration: 0 },
      scales: {
        x: {
          display: true,
          grid: { color: 'rgba(26, 42, 58, 0.5)' },
          ticks: { color: '#5a6a7a', font: { size: 11 }, maxTicksLimit: 10 },
        },
        y: {
          display: true,
          min: 0,
          max: 100,
          grid: { color: 'rgba(26, 42, 58, 0.5)' },
          ticks: {
            color: '#5a6a7a',
            font: { size: 11 },
            callback: v => v + '%',
          },
        },
      },
      plugins: {
        legend: { display: false },
      },
    },
  });
}

// ── Sim control ─────────────────────────────────────────────────────────────
async function startSim() {
  const btn = document.getElementById('startBtn');
  btn.disabled = true;
  btn.textContent = 'Starting...';

  try {
    const res = await fetch('/api/sim/start', { method: 'POST' });
    const data = await res.json();
    if (res.ok) {
      connectSSE();
      document.getElementById('startBtn').classList.add('hidden');
      document.getElementById('stopBtn').classList.remove('hidden');
      document.getElementById('emptyState')?.remove();
    } else {
      btn.disabled = false;
      btn.textContent = 'Start Simulation';
      if (data.msg) addEvent('status', 'STATUS', data.msg);
    }
  } catch (e) {
    btn.disabled = false;
    btn.textContent = 'Start Simulation';
    addEvent('error', 'ERROR', 'Failed to connect to server');
  }
}

async function stopSim() {
  await fetch('/api/sim/stop', { method: 'POST' });
  if (evtSource) { evtSource.close(); evtSource = null; }
  document.getElementById('stopBtn').classList.add('hidden');
  document.getElementById('startBtn').classList.remove('hidden');
  document.getElementById('startBtn').disabled = false;
  document.getElementById('startBtn').textContent = 'Start Simulation';
  setPhase('idle');
  clearInterval(timerInterval);
}

// ── SSE ─────────────────────────────────────────────────────────────────────
function connectSSE() {
  if (evtSource) evtSource.close();
  evtSource = new EventSource('/api/events');

  evtSource.onmessage = (e) => {
    try {
      const event = JSON.parse(e.data);
      handleEvent(event);
    } catch {}
  };

  evtSource.onerror = () => {
    // Reconnect after a short delay
    setTimeout(() => {
      if (evtSource && evtSource.readyState === EventSource.CLOSED) {
        connectSSE();
      }
    }, 2000);
  };
}

// ── Event routing ───────────────────────────────────────────────────────────
function handleEvent(event) {
  const t = event.type;
  const d = event.data || {};
  const ts = event.ts || 0;

  switch (t) {
    case 'price_update':
      addPricePoint(ts, d.price);
      break;

    case 'trade': {
      const dir = d.direction || '?';
      const action = d.action || 'buy';
      if (action === 'sell') {
        addEvent('sell', 'SELL', `${dir} — ${d.summary || d.msg || ''}`, event.role);
      } else if (dir === 'LIMIT') {
        stats.limit++;
        updateStats();
        addEvent('limit', 'LIMIT', d.summary || d.msg || 'Limit order placed', event.role);
      } else {
        if (dir === 'YES') stats.yes++;
        else if (dir === 'NO') stats.no++;
        updateStats();
        addEvent('trade', dir, d.summary || d.msg || `Buy ${dir}`, event.role);
      }
      break;
    }

    case 'news_event':
      showNews(d.message, d.sentiment);
      addEvent('news', 'NEWS', d.message);
      break;

    case 'status':
      addEvent('status', 'STATUS', d.msg || '');
      if (d.msg && d.msg.includes('Simulation started')) {
        simStartTime = Date.now();
        startTimer();
        setPhase('running');
      } else if (d.msg && d.msg.includes('Deploying')) {
        setPhase('deploying');
      } else if (d.msg && d.msg.includes('complete')) {
        setPhase('done');
        clearInterval(timerInterval);
        document.getElementById('stopBtn').classList.add('hidden');
        document.getElementById('startBtn').classList.remove('hidden');
        document.getElementById('startBtn').disabled = false;
        document.getElementById('startBtn').textContent = 'Start Simulation';
      }
      break;

    case 'error':
      stats.errors++;
      updateStats();
      addEvent('error', 'ERR', d.msg || 'Unknown error', event.role);
      break;

    case 'agent_start':
      stats.agentsTotal = Math.max(stats.agentsTotal, (event.agent || 0) + 1);
      updateStats();
      break;

    case 'agent_done':
      stats.agentsDone++;
      updateStats();
      break;

    case 'agent_thought':
      addEvent('thought', event.role || 'THINK', d.thought || d.msg || '', event.role, true);
      break;

    case 'tool_call':
      addEvent('status', 'TOOL', d.cmd ? d.cmd.substring(0, 120) : '', event.role, true);
      break;

    case 'tool_result':
      // Skip — too noisy
      break;
  }
}

// ── Chart ───────────────────────────────────────────────────────────────────
function addPricePoint(ts, price) {
  if (!chart) return;
  const elapsed = simStartTime ? Math.round((ts * 1000 - simStartTime) / 1000) : 0;
  const min = Math.floor(elapsed / 60);
  const sec = String(elapsed % 60).padStart(2, '0');
  chart.data.labels.push(`${min}:${sec}`);
  chart.data.datasets[0].data.push(price);
  // Keep last 500 points
  if (chart.data.labels.length > 500) {
    chart.data.labels.shift();
    chart.data.datasets[0].data.shift();
  }
  chart.update('none');
}

// ── Stats ───────────────────────────────────────────────────────────────────
function updateStats() {
  document.getElementById('statYes').textContent = stats.yes;
  document.getElementById('statNo').textContent = stats.no;
  document.getElementById('statLimit').textContent = stats.limit;
  document.getElementById('statErrors').textContent = stats.errors;
  document.getElementById('statAgents').textContent = `${stats.agentsDone}/${stats.agentsTotal}`;
}

// ── Feed ────────────────────────────────────────────────────────────────────
function addEvent(type, badge, msg, role, dim) {
  const feed = document.getElementById('feed');
  const wasAtBottom = feed.scrollTop + feed.clientHeight >= feed.scrollHeight - 40;

  const el = document.createElement('div');
  el.className = 'event';

  const now = new Date();
  const timeStr = now.toTimeString().substring(0, 5);

  let badgeClass = 'badge-status';
  if (type === 'trade') badgeClass = 'badge-trade';
  else if (type === 'sell') badgeClass = 'badge-sell';
  else if (type === 'limit') badgeClass = 'badge-limit';
  else if (type === 'error') badgeClass = 'badge-error';
  else if (type === 'news') badgeClass = 'badge-news';
  else if (type === 'oracle') badgeClass = 'badge-oracle';
  else if (type === 'thought') badgeClass = 'badge-thought';

  const roleTag = role ? ` <span style="color:var(--text-dim)">[${role}]</span>` : '';
  el.innerHTML = `
    <span class="event-time">${timeStr}</span>
    <span class="event-badge ${badgeClass}">${badge}</span>
    <span class="event-msg ${dim ? 'dim' : ''}">${escapeHtml(msg)}${roleTag}</span>
  `;

  feed.appendChild(el);

  // Keep max 500 events
  while (feed.children.length > 500) feed.removeChild(feed.firstChild);

  if (wasAtBottom) feed.scrollTop = feed.scrollHeight;
}

function escapeHtml(str) {
  const div = document.createElement('div');
  div.textContent = str;
  return div.innerHTML;
}

// ── News banner ─────────────────────────────────────────────────────────────
function showNews(message, sentiment) {
  const banner = document.getElementById('newsBanner');
  banner.textContent = message;
  banner.className = `news-banner visible ${sentiment || 'neutral'}`;
  clearTimeout(banner._hideTimer);
  banner._hideTimer = setTimeout(() => {
    banner.classList.remove('visible');
  }, 30000);
}

// ── Phase indicator ─────────────────────────────────────────────────────────
function setPhase(phase) {
  const el = document.getElementById('phase');
  el.textContent = phase;
  el.className = `phase ${phase}`;
}

// ── Timer ───────────────────────────────────────────────────────────────────
function startTimer() {
  clearInterval(timerInterval);
  timerInterval = setInterval(() => {
    const elapsed = Math.floor((Date.now() - simStartTime) / 1000);
    const em = Math.floor(elapsed / 60);
    const es = String(elapsed % 60).padStart(2, '0');
    const dm = Math.floor(simDuration / 60);
    const ds = String(simDuration % 60).padStart(2, '0');
    document.getElementById('timer').textContent = `${em}:${es} / ${dm}:${ds}`;
  }, 1000);
}

// ── Init ────────────────────────────────────────────────────────────────────
initChart();

// Poll status on load to pick up already-running sim
(async () => {
  try {
    const res = await fetch('/api/sim/status');
    const data = await res.json();
    simDuration = data.duration || 300;
    if (data.running) {
      simStartTime = Date.now() - (data.elapsed * 1000);
      setPhase(data.phase);
      startTimer();
      connectSSE();
      document.getElementById('startBtn').classList.add('hidden');
      document.getElementById('stopBtn').classList.remove('hidden');
      document.getElementById('emptyState')?.remove();
      stats.agentsTotal = data.agents_total;
      stats.agentsDone = data.agents_done;
      updateStats();
    }
  } catch {}
})();
