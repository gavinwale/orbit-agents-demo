"""Simulation lifecycle manager — mutex wrapper around the sim pipeline."""

import json
import logging
import threading
import time
from pathlib import Path

logger = logging.getLogger(__name__)
ROOT = Path(__file__).parent.parent.resolve()


class SimManager:
    def __init__(self):
        self._lock = threading.Lock()
        self._running = False
        self._thread: threading.Thread | None = None
        self._state = None
        self._anvil_proc = None
        self._cfg = None
        self._last_report: str | None = None
        self._phase = "idle"
        self._start_time: float = 0

    @property
    def running(self) -> bool:
        return self._running

    @property
    def state(self):
        return self._state

    @property
    def phase(self) -> str:
        return self._phase

    @property
    def last_report(self) -> str | None:
        return self._last_report

    def status(self) -> dict:
        elapsed = time.time() - self._start_time if self._running else 0
        duration = self._cfg.get("sim_duration_seconds", 300) if self._cfg else 300
        return {
            "running": self._running,
            "phase": self._phase,
            "elapsed": round(elapsed, 1),
            "duration": duration,
            "agents_total": self._state.agents_total if self._state else 0,
            "agents_done": self._state.agents_done if self._state else 0,
        }

    def start(self) -> bool:
        """Start the simulation. Returns False if already running."""
        if not self._lock.acquire(blocking=False):
            return False
        if self._running:
            self._lock.release()
            return False

        self._running = True
        self._start_time = time.time()
        self._phase = "starting"
        self._last_report = None
        self._thread = threading.Thread(target=self._run_sim, daemon=True)
        self._thread.start()
        return True

    def _run_sim(self):
        try:
            from sim.state import SimulationState
            from deploy.deployer import deploy
            from sim import orchestrator

            self._cfg = json.loads((ROOT / "config.json").read_text())
            self._state = SimulationState()

            # Deploy
            self._phase = "deploying"
            self._state.emit({
                "type": "status", "ts": time.time(),
                "data": {"msg": "Deploying contracts to local Anvil chain..."}
            })

            deployment, self._anvil_proc = deploy(ROOT / "config.json")

            self._state.emit({
                "type": "status", "ts": time.time(),
                "data": {"msg": f"Deployed. Markets: {deployment['market_ids']}",
                         "contracts": deployment["contracts"]}
            })

            # Simulate
            self._phase = "running"
            self._state.emit({
                "type": "status", "ts": time.time(),
                "data": {"msg": "Simulation started. Agents are live."}
            })

            orchestrator.run(self._state, self._cfg, deployment)

            # Report
            self._phase = "reporting"
            try:
                from reports.generator import generate_html
                html = generate_html(self._state.report_snapshot(self._cfg))
                self._last_report = html
                results_dir = ROOT / "results"
                results_dir.mkdir(exist_ok=True)
                from datetime import datetime
                ts = datetime.now().strftime("%Y%m%d_%H%M%S")
                (results_dir / f"report_{ts}.html").write_text(html)
            except Exception as exc:
                logger.warning("Report generation failed: %s", exc)

            self._state.emit({
                "type": "status", "ts": time.time(),
                "data": {"msg": "Simulation complete."}
            })
            self._phase = "done"

        except Exception as exc:
            logger.error("Simulation failed: %s", exc, exc_info=True)
            self._phase = "error"
            if self._state:
                self._state.emit({
                    "type": "error", "ts": time.time(),
                    "data": {"msg": f"Simulation crashed: {exc}"}
                })
        finally:
            self._running = False
            self._lock.release()

    def stop(self):
        """Force-stop the simulation by killing Anvil."""
        if self._anvil_proc:
            self._anvil_proc.terminate()
            self._anvil_proc = None
        self._running = False
        self._phase = "idle"
