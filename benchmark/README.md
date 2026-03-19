# Subgraph Benchmark Tool

Compare indexing performance between two subgraph implementations. Measures sync time, storage size, and entity counts by deploying each version to a local graph-node and indexing the same block range.

## Prerequisites

- **Docker** (with Docker Compose v2)
- **Node.js** (18+) and **yarn**
- **PostgreSQL client** (`psql`) — for metrics collection
- **curl** and **jq**
- An **Ethereum/Arbitrum RPC endpoint** (public or private)

### Install psql (if needed)

```bash
# macOS
brew install libpq && brew link --force libpq

# Ubuntu/Debian
sudo apt-get install postgresql-client

# Arch
sudo pacman -S postgresql-libs
```

## Quick Start

### Compare two branches

```bash
cd benchmark
./benchmark.sh main feat/cumulative-factors
```

This will:
1. Spin up graph-node + PostgreSQL + IPFS locally via Docker
2. Check out the `main` branch, build, deploy, and index 1000 blocks
3. Collect storage and entity metrics
4. Reset, then do the same for `feat/cumulative-factors`
5. Generate a comparison report in `benchmark/results/`

### Customize the run

```bash
# Index more blocks for a more representative benchmark
./benchmark.sh main feat/my-branch --blocks 5000

# Use a private RPC for faster indexing
./benchmark.sh main feat/my-branch --rpc https://arb-mainnet.g.alchemy.com/v2/YOUR_KEY

# Keep Docker volumes between runs (faster restarts, less isolation)
./benchmark.sh main feat/my-branch --no-cleanup
```

### All options

```
Usage: benchmark.sh <base_ref> <compare_ref> [options]

Arguments:
  base_ref       Git ref for the baseline (e.g. main, commit SHA)
  compare_ref    Git ref to compare against

Options:
  --blocks N          Blocks to index before stopping (default: 1000)
  --rpc URL           Ethereum RPC endpoint (default: Arbitrum public RPC)
  --network NAME      Network name matching networks.yaml (default: arbitrum-one)
  --poll-interval N   Seconds between progress checks (default: 10)
  --no-cleanup        Keep Docker volumes between runs
  -h, --help          Show help

Environment variables:
  ETHEREUM_RPC        Same as --rpc
  ETHEREUM_NETWORK    Same as --network
  TARGET_BLOCKS       Same as --blocks
```

## Quick Metrics (One-off)

If you already have a subgraph running locally and just want a snapshot:

```bash
# Human-readable output
./metrics.sh

# JSON output (for scripting/CI)
./metrics.sh --json
```

Example output:
```
═══════════════════════════════════════════
  Subgraph Metrics Snapshot
═══════════════════════════════════════════

  Sync Status
  ───────────
  Health:         healthy
  Synced:         false
  Latest block:   6857334
  Chain head:     298123456

  Storage
  ───────
  Database total: 245 MB
  Subgraph data:  189 MB

  Entity Counts (total: 142857)
  ─────────────
  pool                                     85432
  transaction                              28901
  delegator                                12543
  ...
═══════════════════════════════════════════
```

## Understanding the Report

The benchmark generates a Markdown report in `benchmark/results/` with:

### Sync Time
Wall-clock time to index N blocks. This is the primary performance metric — it captures handler execution time, entity writes, and RPC call overhead.

**What to look for:** A PR that adds new entities or heavier handler logic will increase sync time. Anything under ~10% increase for significant new functionality is reasonable.

### Storage Size
Total PostgreSQL storage used by the subgraph's schema tables. Includes row data, indexes, and TOAST tables.

**What to look for:** New entities and fields add storage proportional to the number of events that create/update them. The report shows per-table breakdown so you can see exactly which tables grew.

### Entity Counts
Row counts per table. Helps you understand the cardinality of new entities.

**What to look for:** If a new entity (e.g., `DelegatorSnapshot`) is created on every bond/unbond/rebond event, check the count against the number of those events in the block range to verify the mapping logic is correct.

## Tips for Accurate Benchmarks

1. **Use a private RPC** — Public RPCs rate-limit and add variable latency. An Alchemy/Infura/QuickNode endpoint gives more consistent results.

2. **Index enough blocks** — 1000 blocks is good for a quick sanity check. For production-grade comparisons, use 10,000+ blocks to amortize startup costs.

3. **Run on consistent hardware** — Avoid running benchmarks on a laptop that might thermal-throttle. A dedicated machine or cloud instance gives reproducible numbers.

4. **Run multiple times** — Network and disk I/O vary. Run the benchmark 2-3 times and average the results.

5. **Check the block range** — The start block comes from `networks.yaml`. Arbitrum One starts at block ~5.8M. The first few thousand blocks may have different event density than recent blocks.

## Architecture

```
benchmark/
├── docker-compose.yml  # graph-node + postgres + ipfs
├── benchmark.sh        # Main comparison tool
├── metrics.sh          # Quick metrics snapshot
├── results/            # Generated reports and raw metrics (gitignored)
└── README.md           # This file
```

The benchmark script uses `git worktree` to check out each ref into an isolated directory, builds and deploys the subgraph, monitors indexing progress via graph-node's status API, then queries PostgreSQL directly for storage metrics.

## Troubleshooting

**graph-node won't start**
- Check Docker logs: `docker compose -f benchmark/docker-compose.yml logs graph-node`
- Ensure ports 8000, 8020, 8030, 5001, 5432 are free

**"Missing dependencies" error**
- Install the listed tools. `psql` is the most commonly missing one.

**Subgraph deploy fails**
- Ensure `yarn prepare:<network>` works for the chosen network
- Check that the ref you're benchmarking has a valid `subgraph.template.yaml`

**Slow indexing / RPC errors**
- The default public Arbitrum RPC is rate-limited. Use `--rpc` with a private endpoint.

**Permission denied on benchmark.sh**
- Run `chmod +x benchmark/*.sh`
