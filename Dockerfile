FROM python:3.12-slim

# System deps
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl git build-essential && \
    rm -rf /var/lib/apt/lists/*

# Install Foundry
RUN curl -L https://foundry.paradigm.xyz | bash && \
    /root/.foundry/bin/foundryup
ENV PATH="/root/.foundry/bin:${PATH}"

WORKDIR /app

# Copy foundry config + contracts first (cache layer)
COPY foundry.toml .
COPY contracts-core/ contracts-core/
COPY contracts-oracle/ contracts-oracle/
COPY scripts/ scripts/

# Install Solidity deps via forge
RUN forge install OpenZeppelin/openzeppelin-contracts@v5.4.0 --no-commit && \
    forge install foundry-rs/forge-std@v1.15.0 --no-commit

# Pre-compile contracts (catches errors at build time, caches artifacts)
RUN forge build --via-ir

# Python deps
COPY server/requirements.txt server/requirements.txt
RUN pip install --no-cache-dir -r server/requirements.txt

# Copy everything else
COPY . .

# Create results directory
RUN mkdir -p results

EXPOSE 8000

CMD ["uvicorn", "server.app:app", "--host", "0.0.0.0", "--port", "8000"]
