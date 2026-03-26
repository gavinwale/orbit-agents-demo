# OrbitAgents Demo

Web-hosted simulation of the Orbit Protocol prediction market. Deploys the full contract stack to a local Anvil chain, runs 41 AI agents against it, and streams everything to a live dashboard.

## Deploy to Railway

1. Push this repo to GitHub.
2. Create a new project on [Railway](https://railway.app) and connect the repo.
3. Set environment variables:
   - `PASSWORD` — password for the demo
   - `OPENROUTER_API_KEY` — your [OpenRouter](https://openrouter.ai) API key
4. Deploy. Railway builds the Docker image and starts the server.

## Run locally

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash && foundryup

# Setup
python3 -m venv .venv && source .venv/bin/activate
pip install -r server/requirements.txt

# Install Solidity deps
forge install OpenZeppelin/openzeppelin-contracts@v5.4.0 --no-commit
forge install foundry-rs/forge-std@v1.15.0 --no-commit
forge build --via-ir

# Set env vars
export PASSWORD=demo
export OPENROUTER_API_KEY=sk-or-v1-your-key

# Run
uvicorn server.app:app --host 0.0.0.0 --port 8000
```

Open `http://localhost:8000`, enter the password, and click Start Simulation.
