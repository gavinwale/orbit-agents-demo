"""
deployer.py — deploy the full Orbit Protocol to a local Anvil chain.

Call deploy(config_path) to get back a deployment state dict and the Anvil process.
"""

import json
import logging
import os
import re
import shutil
import subprocess
import time
from pathlib import Path

logger = logging.getLogger(__name__)

AGENTS_DIR = Path(__file__).parent.parent.resolve()
MNEMONIC   = "test test test test test test test test test test test junk"


# ── Helpers ───────────────────────────────────────────────────────────────────

def _foundry_env() -> dict:
    env = os.environ.copy()
    env["PATH"] = ":".join([
        os.path.expanduser("~/.foundry/bin"),
        "/usr/local/bin",
        "/opt/homebrew/bin",
        env.get("PATH", ""),
    ])
    return env


def _run(cmd: str, cwd: Path = None, timeout: int = 120) -> str:
    result = subprocess.run(
        cmd, shell=True,
        cwd=str(cwd or AGENTS_DIR),
        capture_output=True, text=True, timeout=timeout,
        env=_foundry_env(),
        stdin=subprocess.DEVNULL,
    )
    if result.returncode != 0:
        combined = (result.stdout + result.stderr)[-3000:]
        raise RuntimeError(f"Command failed:\n{cmd}\n{combined}")
    return result.stdout + result.stderr


# ── Anvil ─────────────────────────────────────────────────────────────────────

def start_anvil(port: int, accounts: int = 110) -> subprocess.Popen:
    # Kill any stale process on the port
    subprocess.run(f"lsof -ti tcp:{port} | xargs kill -9",
                   shell=True, capture_output=True)
    time.sleep(0.5)

    proc = subprocess.Popen(
        ["anvil", "--host", "127.0.0.1", "--port", str(port),
         "--chain-id", "31337", "--disable-code-size-limit",
         "--accounts", str(accounts), "--balance", "10000",
         "--mnemonic", MNEMONIC],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        env=_foundry_env(),
    )

    rpc = f"http://127.0.0.1:{port}"
    for _ in range(30):
        r = subprocess.run(
            ["cast", "block-number", "--rpc-url", rpc],
            capture_output=True, env=_foundry_env(), timeout=2,
        )
        if r.returncode == 0:
            logger.info("Anvil ready on :%d", port)
            return proc
        time.sleep(0.5)

    raise RuntimeError("Anvil failed to start within 15 seconds")


# ── Library deployment ────────────────────────────────────────────────────────

def deploy_libraries(rpc: str) -> dict:
    """
    1. Clear stale artifacts.
    2. Fresh forge build (no linking — just compiles with unlinked placeholders).
    3. Deploy LPMathLib and SwapExecutor via cast.
    4. Write library addresses back into foundry.toml for forge script linking.
    """
    deploy_pk   = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    deploy_addr = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

    # Clear stale artifacts
    for d in ["out", "cache"]:
        p = AGENTS_DIR / d
        if p.exists():
            shutil.rmtree(p)

    logger.info("Building contracts (fresh compile)…")
    _run("forge build --via-ir 2>&1", cwd=AGENTS_DIR, timeout=180)

    logger.info("Deploying external libraries…")

    def _deploy_lib(lib_name: str) -> str:
        artifact_path = AGENTS_DIR / "out" / f"{lib_name}.sol" / f"{lib_name}.json"
        artifact  = json.loads(artifact_path.read_text())
        bytecode  = artifact["bytecode"]["object"]

        nonce_raw = _run(f"cast nonce {deploy_addr} --rpc-url {rpc}").strip()
        nonce     = int(nonce_raw)
        addr_raw  = _run(f"cast compute-address --nonce {nonce} {deploy_addr}").strip()
        m = re.search(r"(0x[0-9a-fA-F]{40})", addr_raw)
        if not m:
            raise RuntimeError(f"Could not compute address for {lib_name}:\n{addr_raw}")
        expected = m.group(1)

        _run(f"cast send --private-key {deploy_pk} --rpc-url {rpc} --create {bytecode}",
             cwd=AGENTS_DIR)

        logger.info("  %s: %s", lib_name, expected)
        return expected

    lp_math   = _deploy_lib("LPMathLib")
    swap_exec = _deploy_lib("SwapExecutor")

    # Patch foundry.toml with deployed library addresses
    toml_path = AGENTS_DIR / "foundry.toml"
    toml = toml_path.read_text()
    lib_block = (
        '\nlibraries = [\n'
        f'    "contracts-core/libraries/LPMathLib.sol:LPMathLib:{lp_math}",\n'
        f'    "contracts-core/libraries/SwapExecutor.sol:SwapExecutor:{swap_exec}",\n'
        ']\n'
    )
    toml = re.sub(r'\nlibraries\s*=\s*\[.*?\]\n', '\n', toml, flags=re.DOTALL)
    toml_path.write_text(toml.rstrip('\n') + lib_block)

    return {"LPMathLib": lp_math, "SwapExecutor": swap_exec}


# ── Contract deployment ───────────────────────────────────────────────────────

def deploy_contracts(rpc: str) -> dict:
    logger.info("Running DeployFull.s.sol…")
    out = _run(
        "forge script scripts/DeployFull.s.sol:DeployFull "
        f"--rpc-url {rpc} --broadcast --disable-code-size-limit 2>&1",
        cwd=AGENTS_DIR,
        timeout=600,
    )
    m = re.search(r"DEPLOY_JSON:(\{.*\})", out)
    if not m:
        raise RuntimeError(f"Could not find DEPLOY_JSON in output:\n{out[-3000:]}")
    addrs = json.loads(m.group(1))
    logger.info("Contracts deployed: %s", list(addrs.keys()))
    return addrs


# ── Market creation ───────────────────────────────────────────────────────────

def _create_market(rpc: str, contracts: dict, mkt: dict) -> int:
    factory    = contracts["marketFactory"]
    usdc       = contracts["usdc"]
    deploy_pk  = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    threshold  = mkt["funding_threshold"]
    question   = mkt["question"]

    _run(
        f'cast send {factory} '
        f'"createMarket(string,uint128,uint40,uint40)(uint256)" '
        f'"{question}" {threshold} {mkt["funding_duration"]} {mkt["trading_duration"]} '
        f'--private-key {deploy_pk} --rpc-url {rpc}'
    )

    raw = _run(f'cast call {factory} "marketCount()(uint256)" --rpc-url {rpc}').strip()
    market_id = (int(raw, 16) if raw.startswith("0x") else int(raw)) - 1
    logger.info("Market %d: %s", market_id, question[:60])

    half = int(threshold) // 2
    _run(f'cast send {usdc} "approve(address,uint256)" {factory} {threshold} '
         f'--private-key {deploy_pk} --rpc-url {rpc}')
    _run(f'cast send {factory} "contributeLiquidity(uint256,uint128,uint64)" '
         f'{market_id} {half} 600000000000000000 '
         f'--private-key {deploy_pk} --rpc-url {rpc}')
    _run(f'cast send {factory} "contributeLiquidity(uint256,uint128,uint64)" '
         f'{market_id} {half} 400000000000000000 '
         f'--private-key {deploy_pk} --rpc-url {rpc}')
    return market_id


def create_markets(rpc: str, contracts: dict, cfg: dict) -> list:
    markets_cfg = cfg.get("markets") or [cfg["market"]]
    logger.info("Creating %d market(s)…", len(markets_cfg))
    return [_create_market(rpc, contracts, m) for m in markets_cfg]


# ── Wallet derivation ─────────────────────────────────────────────────────────

def derive_wallets(n: int) -> list:
    try:
        from eth_account import Account
        Account.enable_unaudited_hdwallet_features()
    except ImportError:
        logger.warning("eth_account not installed — wallet derivation unavailable")
        return []

    wallets = []
    for i in range(n):
        acct = Account.from_mnemonic(MNEMONIC, account_path=f"m/44'/60'/0'/0/{i}")
        wallets.append({"index": i, "address": acct.address, "pk": acct.key.hex()})
    return wallets


# ── Oracle registration ────────────────────────────────────────────────────────

def register_oracle_roles(rpc: str, contracts: dict, cfg: dict, agent_wallets: list):
    """Register oracle-role agents: proposers → addProposer, voters → addArbitrator."""
    deploy_pk = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    ac  = cfg["agents"]
    t   = ac.get("traders", 0)
    lp  = ac.get("lp", 0)
    arb = ac.get("arb", 0)
    orc = ac.get("oracle", 0)

    oracle_wallets = agent_wallets[t + lp + arb : t + lp + arb + orc]
    orc_prop  = orc // 3
    orc_chal  = orc // 3
    # voters are the remainder after prop + chal

    proposers = oracle_wallets[:orc_prop]
    voters    = oracle_wallets[orc_prop + orc_chal:]

    logger.info("Registering %d proposers and %d voters…", len(proposers), len(voters))

    for w in proposers:
        try:
            _run(f'cast send {contracts["oracle"]} "addProposer(address,bool)" '
                 f'{w["address"]} false --private-key {deploy_pk} --rpc-url {rpc}')
        except Exception as exc:
            logger.warning("Proposer reg skipped for %s: %s", w["address"][:12], exc)

    for w in voters:
        try:
            _run(f'cast send {contracts["oracle"]} "addArbitrator(address)" '
                 f'{w["address"]} --private-key {deploy_pk} --rpc-url {rpc}')
        except Exception as exc:
            logger.warning("Arbitrator reg skipped for %s: %s", w["address"][:12], exc)


# ── Agent funding ─────────────────────────────────────────────────────────────

def fund_agents(rpc: str, contracts: dict, wallets: list, usdc_each: str):
    logger.info("Funding %d agent wallets…", len(wallets))
    deploy_pk = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    for w in wallets:
        _run(f'cast send {contracts["usdc"]} "transfer(address,uint256)(bool)" '
             f'{w["address"]} {usdc_each} '
             f'--private-key {deploy_pk} --rpc-url {rpc}')
    logger.info("Agent funding complete")


# ── Main entry point ──────────────────────────────────────────────────────────

def deploy(config_path: Path = None) -> tuple:
    """
    Full deployment: Anvil → libraries → contracts → markets → wallets → funding → oracle reg.

    Returns (state_dict, anvil_process).
    """
    cfg  = json.loads((config_path or AGENTS_DIR / "config.json").read_text())
    rpc  = cfg["rpc"]
    port = cfg["anvil_port"]

    anvil      = start_anvil(port)
    _          = deploy_libraries(rpc)
    contracts  = deploy_contracts(rpc)
    market_ids = create_markets(rpc, contracts, cfg)

    total_agents  = sum(cfg["agents"].values())
    wallets       = derive_wallets(total_agents + 1)   # +1 for deployer at index 0
    agent_wallets = wallets[1:]

    fund_agents(rpc, contracts, agent_wallets, cfg["funding"]["usdc_per_agent"])
    register_oracle_roles(rpc, contracts, cfg, agent_wallets)

    markets_cfg = cfg.get("markets") or [cfg.get("market", {})]
    state = {
        "rpc":         rpc,
        "contracts":   contracts,
        "market_ids":  market_ids,
        "market_id":   market_ids[0],     # backward-compat
        "markets_cfg": markets_cfg,
        "wallets":     wallets,
    }

    state_path = AGENTS_DIR / "deployment.json"
    state_path.write_text(json.dumps(state, indent=2))
    logger.info("Deployment state written to %s", state_path)

    return state, anvil
