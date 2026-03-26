"""SimulationState — thread-safe container for all shared simulation data."""

import threading
import time
from dataclasses import dataclass, field
from typing import Dict, List


@dataclass
class AgentStat:
    role:   str
    yes:    int = 0
    no:     int = 0
    limit:  int = 0
    errors: int = 0
    turns:  int = 0


class SimulationState:
    """
    Single source of truth for all mutable simulation data.

    All public methods are thread-safe via an internal lock.
    Read-only snapshots (used by the dashboard) are returned as plain dicts/lists
    so callers never hold the lock while serialising to JSON.
    """

    def __init__(self):
        self._lock = threading.Lock()

        # ── Timing ───────────────────────────────────────────────────────────
        self.sim_start: float = 0.0
        self.sim_end:   float = 0.0

        # ── Counters ─────────────────────────────────────────────────────────
        self.agents_total: int = 0
        self.agents_done:  int = 0
        self.trades: Dict[str, int] = {"YES": 0, "NO": 0, "LIMIT": 0}
        self.sells:  int = 0
        self.errors: int = 0

        # ── Time-series ───────────────────────────────────────────────────────
        self.market_prices: List[dict] = []   # {ts, price, market_id, question}

        # ── Lookup tables ─────────────────────────────────────────────────────
        self.agent_roles: Dict[int, str]    = {}   # idx → role
        self.agent_stats: Dict[int, AgentStat] = {}

        # ── News ──────────────────────────────────────────────────────────────
        self.news_log:    List[str]  = []    # ordered list of news messages shown
        self.news_prices: List[dict] = []    # {msg, sentiment, ts}

        # ── SSE subscribers ───────────────────────────────────────────────────
        import queue
        self._events:      List[dict]        = []
        self._subscribers: List[queue.Queue] = []

    # ─────────────────────────────────────────────────────────────────────────
    # Event bus
    # ─────────────────────────────────────────────────────────────────────────

    def emit(self, event: dict):
        """Append event to log, fan-out to all SSE subscribers, update stats."""
        import queue as _queue
        with self._lock:
            self._events.append(event)
            for q in list(self._subscribers):
                try:
                    q.put_nowait(event)
                except _queue.Full:
                    pass

        self._update_stats(event)

    def subscribe(self):
        """Return a new queue pre-loaded with the current event snapshot."""
        import queue as _queue
        q = _queue.Queue(maxsize=2000)
        with self._lock:
            snapshot = list(self._events)
            self._subscribers.append(q)
        for e in snapshot:
            try:
                q.put_nowait(e)
            except _queue.Full:
                break
        return q

    def unsubscribe(self, q):
        with self._lock:
            try:
                self._subscribers.remove(q)
            except ValueError:
                pass

    # ─────────────────────────────────────────────────────────────────────────
    # Stats updates (called without the lock — operates on thread-safe primitives
    # or is idempotent under duplicate events)
    # ─────────────────────────────────────────────────────────────────────────

    def _ensure_agent(self, idx: int, role: str):
        if idx not in self.agent_stats:
            self.agent_stats[idx] = AgentStat(role=role)
        if idx not in self.agent_roles:
            self.agent_roles[idx] = role

    def _update_stats(self, event: dict):
        t    = event.get("type")
        idx  = event.get("agent")
        role = event.get("role", "?")

        if t == "trade":
            d         = event.get("data", {})
            direction = d.get("direction", "?")
            action    = d.get("action", "buy")
            with self._lock:
                self.trades[direction] = self.trades.get(direction, 0) + 1
                if action == "sell":
                    self.sells += 1
                if idx is not None:
                    self._ensure_agent(idx, role)
                    stat = self.agent_stats[idx]
                    if direction == "YES":    stat.yes   += 1
                    elif direction == "NO":   stat.no    += 1
                    elif direction == "LIMIT":stat.limit += 1

        elif t == "error":
            with self._lock:
                self.errors += 1
                if idx is not None:
                    self._ensure_agent(idx, role)
                    self.agent_stats[idx].errors += 1

        elif t == "agent_done":
            with self._lock:
                self.agents_done += 1
                if idx is not None:
                    self._ensure_agent(idx, role)
                    self.agent_stats[idx].turns = event.get("data", {}).get("turns", 0)

        elif t == "price_update":
            d = event["data"]
            with self._lock:
                self.market_prices.append({
                    "ts":        event["ts"],
                    "price":     d["price"],
                    "market_id": d.get("market_id", 0),
                    "question":  d.get("question", ""),
                })

        elif t == "news_event":
            d   = event["data"]
            msg = d.get("message", "")
            with self._lock:
                self.news_log.append(msg)
                self.news_prices.append({
                    "msg": msg, "sentiment": d.get("sentiment", "neutral"),
                    "ts":  event.get("ts", time.time()),
                })

        elif t == "agent_start":
            if idx is not None:
                with self._lock:
                    self._ensure_agent(idx, role)

    # ─────────────────────────────────────────────────────────────────────────
    # Read-only snapshots (no lock held during JSON serialisation)
    # ─────────────────────────────────────────────────────────────────────────

    def dashboard_snapshot(self, cfg: dict) -> dict:
        import time as _time
        with self._lock:
            markets_cfg = cfg.get("markets") or [cfg.get("market", {})]
            return {
                "project":   cfg.get("project", "OrbitAgents"),
                "model":     cfg.get("model", "?"),
                "rpc":       cfg.get("rpc", ""),
                "stats": {
                    "agents_done":  self.agents_done,
                    "agents_total": self.agents_total,
                    "trades":       dict(self.trades),
                    "errors":       self.errors,
                    "sells":        self.sells,
                },
                "roles":     dict(self.agent_roles),
                "prices":    list(self.market_prices[-400:]),
                "sim_start": self.sim_start,
                "sim_end":   self.sim_end,
                "now":       _time.time(),
                "markets":   [m.get("question", "") for m in markets_cfg],
                "news":      list(self.news_log[-5:]),
            }

    def report_snapshot(self, cfg: dict) -> dict:
        import time as _time
        with self._lock:
            markets_cfg = cfg.get("markets") or [cfg.get("market", {})]
            return {
                "prices":      list(self.market_prices),
                "agent_stats": {k: vars(v) for k, v in self.agent_stats.items()},
                "stats": {
                    "agents_done":  self.agents_done,
                    "agents_total": self.agents_total,
                    "trades":       dict(self.trades),
                    "errors":       self.errors,
                    "sells":        self.sells,
                },
                "news_prices": list(self.news_prices),
                "model":       cfg.get("model", "?"),
                "markets":     [m.get("question", "") for m in markets_cfg],
                "sim_start":   self.sim_start,
                "sim_end":     _time.time(),
            }
