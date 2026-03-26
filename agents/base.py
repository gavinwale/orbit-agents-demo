"""BaseAgent — OpenRouter-powered agentic loop with a single bash tool."""

import json
import logging
import os
import queue
import random
import re
import subprocess
import time
from pathlib import Path

import openai

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


BASH_TOOL = {
    "type": "function",
    "function": {
        "name": "bash",
        "description": (
            "Run a bash command. Foundry tools (cast, forge, anvil) are on PATH. "
            "Use cast call to read contract state. Use cast send to submit transactions."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "command": {"type": "string", "description": "Bash command to execute"}
            },
            "required": ["command"],
        },
    },
}


class BaseAgent:
    """
    One AI agent in the simulation.

    Each agent owns a per-agent queue (`event_queue`) that the orchestrator
    drains into the shared SimulationState event bus.
    """

    def __init__(
        self,
        idx: int,
        role: str,
        wallet: dict,
        system_prompt: str,
        config: dict,
        event_queue: queue.Queue,
        end_time: float = None,
    ):
        self.idx      = idx
        self.role     = role
        self.wallet   = wallet
        self.system   = system_prompt
        self.cfg      = config
        self.eq       = event_queue
        self.turns    = 0
        self.end_time = end_time or (time.time() + config.get("sim_duration_seconds", 3600))

        api_key = os.environ.get("OPENROUTER_API_KEY", "")
        if not api_key:
            env_file = AGENTS_DIR / ".env"
            if env_file.exists():
                for line in env_file.read_text().splitlines():
                    if line.startswith("OPENROUTER_API_KEY="):
                        api_key = line.split("=", 1)[1].strip().strip('"').strip("'")

        self.client = openai.OpenAI(
            base_url="https://openrouter.ai/api/v1",
            api_key=api_key,
        )

    # ── Event emission ────────────────────────────────────────────────────────

    def _emit(self, event_type: str, data: dict):
        try:
            self.eq.put_nowait({
                "type":  event_type,
                "agent": self.idx,
                "role":  self.role,
                "data":  data,
                "ts":    time.time(),
            })
        except queue.Full:
            pass

    # ── Command safety ─────────────────────────────────────────────────────

    # Allowlisted command prefixes — everything else is rejected.
    _ALLOWED_PREFIXES = ("cast ", "forge ", "curl ", "echo ", "printf ", "python3 -c")

    # Blocklisted patterns — rejected even if the prefix is allowed.
    _BLOCKED_PATTERNS = [
        r"\brm\s",                  # rm anything
        r"\bmv\s",                  # mv (move/rename files)
        r"\bchmod\b",              # permission changes
        r"\bchown\b",              # ownership changes
        r"\bkill\b",              # process killing
        r"\bpkill\b",
        r"\bkillall\b",
        r"\bshutdown\b",
        r"\breboot\b",
        r"\bmkfs\b",
        r"\bdd\b\s",              # disk destroyer
        r"\bsudo\b",
        r"\bsu\b\s",
        r">\s*/",                  # redirect to root filesystem
        r"\bwget\b",              # no downloading arbitrary binaries
        r"\bapt\b",
        r"\bbrew\b",
        r"\bnpm\b",
        r"\bpip\b",
        r"\|.*\bsh\b",            # piping into shell
        r"\|.*\bbash\b",
        r"`.*`",                  # backtick subshells
        r"\$\(",                  # command substitution
        r"\bsource\b",
        r"\beval\b",
        r"\.env",                 # don't touch env files
        r"/etc/",                 # stay out of system dirs
        r"/usr/",
        r"/var/",
        r"~\/\.",                 # dotfiles
    ]

    @classmethod
    def _validate_command(cls, command: str) -> str | None:
        """Return an error message if the command is unsafe, else None."""
        cmd = command.strip()

        # Must start with an allowed prefix
        if not any(cmd.startswith(p) for p in cls._ALLOWED_PREFIXES):
            return f"Blocked: command must start with one of {cls._ALLOWED_PREFIXES}"

        # Must not contain blocked patterns
        for pattern in cls._BLOCKED_PATTERNS:
            if re.search(pattern, cmd):
                return f"Blocked: command matches forbidden pattern '{pattern}'"

        return None

    # ── Bash execution ────────────────────────────────────────────────────────

    def _run_bash(self, command: str, timeout: int = 60) -> str:
        # Safety check — reject anything that isn't a known-safe command
        violation = self._validate_command(command)
        if violation:
            logger.warning("Agent %d command blocked: %s — %s",
                           self.idx, command[:120], violation)
            self._emit("tool_call", {"command": command[:300], "target": "BLOCKED"})
            self._emit("tool_result", {
                "output":    violation,
                "exit_code": -1,
                "success":   False,
                "target":    "BLOCKED",
            })
            return violation

        target = _infer_contract(command)
        self._emit("tool_call", {"command": command[:300], "target": target})
        try:
            r = subprocess.run(
                command, shell=True, cwd=str(AGENTS_DIR),
                capture_output=True, text=True, timeout=timeout,
                env=_foundry_env(),
            )
            output  = (r.stdout + r.stderr).strip()
            display = output[:2000] + ("…" if len(output) > 2000 else "")
            self._emit("tool_result", {
                "output":    display,
                "exit_code": r.returncode,
                "success":   r.returncode == 0,
                "target":    target,
            })
            self._detect_trade(command, r.returncode)
            return output[:10000]
        except subprocess.TimeoutExpired:
            self._emit("tool_result", {"output": "timeout", "exit_code": -1,
                                       "success": False, "target": target})
            return "timeout"
        except Exception as exc:
            self._emit("tool_result", {"output": str(exc), "exit_code": -1,
                                       "success": False, "target": target})
            return str(exc)

    def _detect_trade(self, command: str, returncode: int):
        """Parse completed cast send commands to emit structured trade events."""
        if returncode != 0:
            return
        cmd = command.lower()
        if "buyyes"          in cmd: self._emit("trade", {"direction": "YES",   "action": "buy"})
        elif "buyno"         in cmd: self._emit("trade", {"direction": "NO",    "action": "buy"})
        elif "sellyes"       in cmd: self._emit("trade", {"direction": "YES",   "action": "sell"})
        elif "sellno"        in cmd: self._emit("trade", {"direction": "NO",    "action": "sell"})
        elif "placelimitbuy" in cmd: self._emit("trade", {"direction": "LIMIT", "action": "place"})
        elif "claimlimitorder" in cmd: self._emit("trade", {"direction": "LIMIT", "action": "claim"})

    # ── Decision cycle ────────────────────────────────────────────────────────

    def _run_cycle(self):
        """One decision: call the model, execute any tool calls, until done."""
        messages = [{"role": "user",
                     "content": "Make your next move. Check market state then execute your strategy."}]
        consecutive_errors = 0

        for _ in range(8):   # cap at 8 LLM rounds per cycle
            try:
                resp = self.client.chat.completions.create(
                    model=self.cfg.get("model", "deepseek/deepseek-chat"),
                    max_tokens=self.cfg.get("agent_max_tokens", 1024),
                    messages=[{"role": "system", "content": self.system}] + messages,
                    tools=[BASH_TOOL],
                    tool_choice="auto",
                )
                consecutive_errors = 0
            except openai.RateLimitError:
                wait = 45 + random.uniform(0, 30)
                logger.warning("Agent %d rate-limited; waiting %ds", self.idx, int(wait))
                self._emit("status", {"msg": f"Agent {self.idx} rate-limited, waiting {int(wait)}s"})
                time.sleep(wait)
                continue
            except Exception as exc:
                consecutive_errors += 1
                logger.debug("Agent %d API error: %s", self.idx, exc)
                self._emit("error", {"msg": str(exc)})
                if consecutive_errors >= 3:
                    return
                time.sleep(10)
                continue

            msg = resp.choices[0].message

            # Normalise tool calls for the message history
            tool_calls_payload = [
                {"id": tc.id, "type": "function",
                 "function": {"name": tc.function.name, "arguments": tc.function.arguments}}
                for tc in (msg.tool_calls or [])
            ]
            messages.append({
                "role":    "assistant",
                "content": msg.content or "",
                **({"tool_calls": tool_calls_payload} if tool_calls_payload else {}),
            })

            if msg.content:
                self._emit("agent_thought", {"text": msg.content[:300]})

            if not msg.tool_calls:
                break   # model is done thinking for this cycle

            # Execute tool calls
            for tc in msg.tool_calls:
                if tc.function.name == "bash":
                    args   = json.loads(tc.function.arguments)
                    result = self._run_bash(args["command"])
                    messages.append({
                        "role":         "tool",
                        "tool_call_id": tc.id,
                        "content":      result,
                    })

        self.turns += 1

    # ── Main loop ─────────────────────────────────────────────────────────────

    def run(self):
        self._emit("agent_start", {"role": self.role, "address": self.wallet["address"]})
        # Stagger startup to avoid thundering-herd on the RPC and the LLM API
        time.sleep(random.uniform(0, 30))

        duration = self.cfg.get("sim_duration_seconds", 3600)
        min_wait = max(8,  duration * 0.012)
        max_wait = max(15, duration * 0.025)

        while time.time() < self.end_time:
            self._run_cycle()

            remaining = self.end_time - time.time()
            if remaining <= 0:
                break
            wait = min(random.uniform(min_wait, max_wait), remaining)
            self._emit("agent_idle", {"wait": int(wait)})
            time.sleep(wait)

        self._emit("agent_done", {"turns": self.turns})
        logger.debug("Agent %d (%s) done after %d turns", self.idx, self.role, self.turns)


# ── Contract inference ────────────────────────────────────────────────────────

def _infer_contract(command: str) -> str:
    """Heuristic: guess which contract a cast command targets (for visualisation)."""
    c = command.lower()
    if "setapprovalforall" in c:                                     return "outcometoken"
    if "balanceof" in c or "approve" in c or "transfer" in c:       return "usdc"
    if "buyyes" in c or "buyno" in c:                                return "router"
    if "sellyes" in c or "sellno" in c:                              return "router"
    if "placelimitbuy" in c or "placelimitsell" in c:                return "router"
    if "withdrawlimitorder" in c or "claimlimitorder" in c:          return "router"
    if "quotebuy" in c or "quotesell" in c:                          return "router"
    if "collectfees" in c or "claimlpfees" in c:                     return "router"
    if "getspotprice" in c or "getmarketstatus" in c or "twap" in c: return "viewer"
    if "proposeoutcome" in c or "createresolution" in c or "challengeoutcome" in c: return "oracle"
    if "getresolution" in c or "finalize" in c or "vote" in c:       return "oracle"
    if "contributeliquidity" in c or "createmarket" in c:            return "factory"
    if "rebalance" in c or "removeliquidity" in c or "getmarketlpstate" in c: return "lpmgr"
    if "getyestokenid" in c or "getnotokenid" in c:                  return "outcometoken"
    return "router"
