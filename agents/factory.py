"""
Agent factory — builds the full agent roster from config.

All persona imports live here so the rest of the codebase never has
to know which file a persona lives in.
"""

import queue
from typing import List, Tuple

from agents.base import BaseAgent
from agents.roles.traders      import PROMPTS as TRADER_PROMPTS
from agents.roles.market_makers import PROMPTS as MM_PROMPTS
from agents.roles.arbitrageurs  import PROMPTS as ARB_PROMPTS
from agents.roles.oracle        import PROMPTS as ORACLE_PROMPTS
from agents.roles.adversarial   import PROMPTS as ADV_PROMPTS

# Combined lookup: role_name → prompt template
ALL_PROMPTS: dict = {
    **TRADER_PROMPTS,
    **MM_PROMPTS,
    **ARB_PROMPTS,
    **ORACLE_PROMPTS,
    **ADV_PROMPTS,
}


def get_prompt(role: str, **kwargs) -> str:
    """Render the persona template for `role` with the given keyword arguments."""
    template = ALL_PROMPTS.get(role, ALL_PROMPTS["trader_neutral"])
    kwargs.setdefault("duration", 3600)
    return template.format(**kwargs)


def _role_schedule(cfg: dict) -> List[Tuple[str, int]]:
    """
    Return an ordered list of (role_name, count) tuples matching the
    agent counts in config.json.
    """
    ac   = cfg["agents"]
    t    = ac["traders"]
    lp   = ac["lp"]
    arb  = ac["arb"]
    orc  = ac["oracle"]
    adv  = ac["adversarial"]

    # Trader sub-types
    t_bull      = t // 4
    t_bear      = t // 4
    t_neutral   = t // 5
    t_remaining = t - t_bull - t_bear - t_neutral
    t_panic     = t_remaining // 2
    t_momentum  = t_remaining - t_panic

    # Oracle sub-types
    orc_prop  = orc // 3
    orc_chal  = orc // 3
    orc_vote  = orc - orc_prop - orc_chal

    # Adversarial sub-types
    adv_exploit = adv // 2
    adv_drain   = adv // 4
    adv_fuzz    = adv - adv_exploit - adv_drain

    return [
        ("trader_bull",        t_bull),
        ("trader_bear",        t_bear),
        ("trader_neutral",     t_neutral),
        ("panic_seller",       t_panic),
        ("momentum_trader",    t_momentum),
        ("lp",                 lp),
        ("arb",                arb),
        ("oracle_proposer",    orc_prop),
        ("oracle_challenger",  orc_chal),
        ("oracle_voter",       orc_vote),
        ("adversarial",        adv_exploit),
        ("adversarial_drain",  adv_drain),
        ("adversarial_fuzzer", adv_fuzz),
    ]


def build_agents(state, cfg: dict, deployment: dict) -> List[Tuple[BaseAgent, queue.Queue]]:
    """
    Instantiate all agents and register their roles on `state`.

    Returns a list of (agent, event_queue) tuples ready for concurrent execution.
    """
    contracts   = deployment["contracts"]
    wallets     = deployment["wallets"][1:]   # index 0 is the deployer
    market_ids  = deployment.get("market_ids", [deployment.get("market_id", 0)])
    markets_cfg = deployment.get("markets_cfg") or cfg.get("markets") or [cfg.get("market", {})]
    rpc         = deployment["rpc"]
    duration    = cfg.get("sim_duration_seconds", 3600)

    schedule  = _role_schedule(cfg)
    agents    = []
    wallet_i  = 0

    for role, count in schedule:
        for _ in range(count):
            if wallet_i >= len(wallets):
                break
            wallet = wallets[wallet_i]

            # Distribute agents across markets round-robin
            mkt_i     = wallet_i % len(market_ids)
            market_id = market_ids[mkt_i]
            question  = (markets_cfg[mkt_i].get("question", "?")
                         if mkt_i < len(markets_cfg) else "?")

            prompt = get_prompt(
                role,
                address=wallet["address"],
                pk=wallet["pk"],
                duration=duration,
                rpc=rpc,
                market_id=market_id,
                question=question,
                **contracts,
            )

            eq    = queue.Queue(maxsize=500)
            agent = BaseAgent(
                idx=wallet_i,
                role=role,
                wallet=wallet,
                system_prompt=prompt,
                config=cfg,
                event_queue=eq,
                end_time=state.sim_end,
            )

            # Register role so the dashboard can colour agents before they start
            with state._lock:
                state.agent_roles[wallet_i] = role

            agents.append((agent, eq))
            wallet_i += 1

    return agents
