"""Simulation orchestrator — wires agents, pollers, and news together."""

import logging
import os
import queue
import random
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

logger = logging.getLogger(__name__)

AGENTS_DIR = Path(__file__).parent.parent.resolve()


def _foundry_env() -> dict:
    env = os.environ.copy()
    env["PATH"] = ":".join([
        os.path.expanduser("~/.foundry/bin"),
        "/usr/local/bin",
        "/opt/homebrew/bin",
        env.get("PATH", ""),
    ])
    return env


# ── Market price poller ───────────────────────────────────────────────────────

def _poll_market(state, contracts: dict, rpc: str, market_id: int, question: str,
                 interval: int = 5):
    """Read on-chain YES probability every `interval` seconds; emit price_update."""
    first = True
    while True:
        try:
            r = subprocess.run(
                f'cast call {contracts["marketCore"]} '
                f'"getCurrentProbability(uint256)(uint256)" {market_id} --rpc-url {rpc}',
                shell=True, capture_output=True, text=True, timeout=5,
                env=_foundry_env(),
            )
            if r.returncode == 0:
                raw = r.stdout.strip().split()[0]
                prob_1e18 = int(raw, 16) if raw.startswith("0x") else int(raw)
                prob_pct  = round(prob_1e18 / 1e16, 2)
                if 0 < prob_pct < 100:
                    if first:
                        logger.info("Price poller live: market %d → %.1f%% YES", market_id, prob_pct)
                        first = False
                    state.emit({
                        "type": "price_update",
                        "ts":   time.time(),
                        "data": {
                            "price":     prob_pct,
                            "market_id": market_id,
                            "question":  question[:40],
                        },
                    })
            else:
                if first:
                    logger.debug("Price poller: market %d not yet active", market_id)
        except Exception as exc:
            if first:
                logger.warning("Price poller error: %s", exc)
        time.sleep(interval)


# ── News scheduler ────────────────────────────────────────────────────────────

def _run_news(state, news_events: list, sim_start: float):
    """Fire scripted news events at their configured offsets after sim_start."""
    for event in sorted(news_events, key=lambda e: e["delay_seconds"]):
        fire_at = sim_start + event["delay_seconds"]
        wait    = max(0, fire_at - time.time())
        time.sleep(wait)
        msg       = event["message"]
        sentiment = event.get("sentiment", "neutral")
        logger.info("NEWS [+%ds]: %s", event["delay_seconds"], msg)
        state.emit({
            "type": "news_event",
            "ts":   time.time(),
            "data": {"message": msg, "sentiment": sentiment},
        })


# ── Agent event forwarding ────────────────────────────────────────────────────

def _forward_events(state, agent_queue: queue.Queue):
    """Drain an agent's per-agent queue into the shared state/event bus."""
    while True:
        try:
            event = agent_queue.get(timeout=1)
            state.emit(event)
        except queue.Empty:
            continue


# ── Main run ──────────────────────────────────────────────────────────────────

def run(state, cfg: dict, deployment: dict):
    """
    Build and run all agents against an already-deployed chain.

    Parameters
    ----------
    state      : SimulationState
    cfg        : parsed config.json
    deployment : dict returned by deploy.deployer.deploy()
    """
    from agents.factory import build_agents

    duration    = cfg.get("sim_duration_seconds", 3600)
    concurrency = cfg.get("agent_concurrency", 10)

    # Set wall-clock timing on state
    state.sim_start = time.time()
    state.sim_end   = state.sim_start + duration

    contracts  = deployment["contracts"]
    rpc        = deployment["rpc"]
    market_ids = deployment.get("market_ids", [deployment.get("market_id", 0)])
    markets_cfg = deployment.get("markets_cfg") or cfg.get("markets") or [cfg.get("market", {})]

    # ── Start one price poller per market ─────────────────────────────────────
    for i, mid in enumerate(market_ids):
        question = markets_cfg[i].get("question", "") if i < len(markets_cfg) else ""
        threading.Thread(
            target=_poll_market,
            args=(state, contracts, rpc, mid, question),
            daemon=True,
            name=f"poller-{mid}",
        ).start()

    # ── Build agents ──────────────────────────────────────────────────────────
    agents_and_queues = build_agents(state, cfg, deployment)
    random.shuffle(agents_and_queues)   # mix roles across the concurrency pool
    state.agents_total = len(agents_and_queues)

    state.emit({"type": "status", "ts": time.time(),
                "data": {"msg": f"Starting {len(agents_and_queues)} agents"}})

    # Start per-agent event forwarding threads
    for _, aq in agents_and_queues:
        threading.Thread(target=_forward_events, args=(state, aq),
                         daemon=True, name="event-fwd").start()

    # ── News scheduler ────────────────────────────────────────────────────────
    news_events = cfg.get("news_events", [])
    if news_events:
        threading.Thread(
            target=_run_news,
            args=(state, news_events, state.sim_start),
            daemon=True,
            name="news",
        ).start()
        logger.info("News: %d events scheduled", len(news_events))

    # ── Run agents concurrently ───────────────────────────────────────────────
    def _run_agent(agent_queue_tuple):
        agent, _ = agent_queue_tuple
        try:
            agent.run()
        except Exception as exc:
            agent._emit("error", {"msg": str(exc)})

    with ThreadPoolExecutor(max_workers=concurrency, thread_name_prefix="agent") as pool:
        futures = {pool.submit(_run_agent, aq): aq for aq in agents_and_queues}
        for future in as_completed(futures):
            try:
                future.result()
            except Exception as exc:
                state.emit({"type": "error", "ts": time.time(), "data": {"msg": str(exc)}})

    state.emit({"type": "status", "ts": time.time(),
                "data": {"msg": "All agents completed. Dashboard still live."}})
    logger.info("Simulation complete — all %d agents done", len(agents_and_queues))
