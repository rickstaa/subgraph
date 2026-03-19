#!/usr/bin/env bash
#
# Subgraph Benchmark Tool
#
# Compares indexing performance (sync time, storage size, entity counts)
# between two git refs (branches, commits, or tags).
#
# Usage:
#   ./benchmark.sh <base_ref> <compare_ref> [options]
#
# Examples:
#   ./benchmark.sh main feat/cumulative-factors
#   ./benchmark.sh main feat/cumulative-factors --blocks 1000
#   ./benchmark.sh abc123 def456 --rpc https://my-rpc.example.com
#
# Requirements:
#   - Docker & Docker Compose
#   - Node.js & yarn
#   - git
#   - psql (PostgreSQL client)
#   - curl & jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Defaults ────────────────────────────────────────────────────────────────
TARGET_BLOCKS="${TARGET_BLOCKS:-1000}"
ETHEREUM_RPC="${ETHEREUM_RPC:-https://arb1.arbitrum.io/rpc}"
ETHEREUM_NETWORK="${ETHEREUM_NETWORK:-arbitrum-one}"
POLL_INTERVAL=10          # seconds between progress checks
SUBGRAPH_NAME="livepeer/livepeer"
GRAPHQL_URL="http://127.0.0.1:8000/subgraphs/name/${SUBGRAPH_NAME}"
STATUS_URL="http://127.0.0.1:8030/graphql"
DEPLOY_URL="http://127.0.0.1:8020"
IPFS_URL="http://127.0.0.1:5001"
PG_CONN="postgresql://graph-node:let-me-in@127.0.0.1:5432/graph-node"
RESULTS_DIR="$SCRIPT_DIR/results"
CLEANUP="${CLEANUP:-true}"

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ─── Helpers ─────────────────────────────────────────────────────────────────

log()  { echo -e "${BLUE}[benchmark]${NC} $*"; }
warn() { echo -e "${YELLOW}[benchmark]${NC} $*"; }
err()  { echo -e "${RED}[benchmark]${NC} $*" >&2; }
ok()   { echo -e "${GREEN}[benchmark]${NC} $*"; }

usage() {
  cat <<EOF
Usage: $(basename "$0") <base_ref> <compare_ref> [options]

Arguments:
  base_ref       Git ref for the baseline (e.g. main, commit SHA)
  compare_ref    Git ref to compare against

Options:
  --blocks N          Number of blocks to index before stopping (default: $TARGET_BLOCKS)
  --rpc URL           Ethereum RPC endpoint (default: Arbitrum public RPC)
  --network NAME      Network name matching networks.yaml (default: arbitrum-one)
  --poll-interval N   Seconds between progress checks (default: $POLL_INTERVAL)
  --no-cleanup        Keep Docker volumes between runs (faster re-runs, less isolation)
  -h, --help          Show this help message

Environment variables:
  ETHEREUM_RPC        Same as --rpc
  ETHEREUM_NETWORK    Same as --network
  TARGET_BLOCKS       Same as --blocks
EOF
  exit 0
}

# ─── Parse Arguments ─────────────────────────────────────────────────────────

if [[ $# -lt 2 ]]; then
  usage
fi

BASE_REF="$1"; shift
COMPARE_REF="$1"; shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --blocks)        TARGET_BLOCKS="$2"; shift 2 ;;
    --rpc)           ETHEREUM_RPC="$2"; shift 2 ;;
    --network)       ETHEREUM_NETWORK="$2"; shift 2 ;;
    --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
    --no-cleanup)    CLEANUP="false"; shift ;;
    -h|--help)       usage ;;
    *)               err "Unknown option: $1"; usage ;;
  esac
done

# ─── Preflight Checks ───────────────────────────────────────────────────────

check_deps() {
  local missing=()
  for cmd in docker git node yarn psql curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  # Check for docker compose (v2 plugin or standalone)
  if ! docker compose version &>/dev/null 2>&1 && ! command -v docker-compose &>/dev/null; then
    missing+=("docker-compose")
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing dependencies: ${missing[*]}"
    exit 1
  fi
}

docker_compose() {
  if docker compose version &>/dev/null 2>&1; then
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" "$@"
  else
    docker-compose -f "$SCRIPT_DIR/docker-compose.yml" "$@"
  fi
}

# ─── Infrastructure ─────────────────────────────────────────────────────────

start_infra() {
  log "Starting graph-node infrastructure..."
  ETHEREUM_RPC="$ETHEREUM_RPC" ETHEREUM_NETWORK="$ETHEREUM_NETWORK" \
    docker_compose up -d

  log "Waiting for graph-node to be ready..."
  local retries=0
  until curl -sf "$DEPLOY_URL" &>/dev/null || [[ $retries -ge 60 ]]; do
    sleep 2
    retries=$((retries + 1))
  done

  if [[ $retries -ge 60 ]]; then
    err "graph-node failed to start after 120s"
    docker_compose logs graph-node | tail -30
    exit 1
  fi
  ok "graph-node is ready"
}

stop_infra() {
  log "Stopping infrastructure..."
  docker_compose down
  if [[ "$CLEANUP" == "true" ]]; then
    docker_compose down -v
  fi
}

reset_infra() {
  log "Resetting infrastructure (clean volumes)..."
  docker_compose down -v 2>/dev/null || true
  start_infra
}

# ─── Subgraph Build & Deploy ────────────────────────────────────────────────

checkout_and_build() {
  local ref="$1"
  local workdir="$2"

  log "Checking out $ref into $workdir..."
  if [[ -d "$workdir" ]]; then
    rm -rf "$workdir"
  fi

  git -C "$REPO_ROOT" worktree add "$workdir" "$ref" 2>/dev/null || {
    # If ref is a remote branch not yet local
    git -C "$REPO_ROOT" fetch origin "$ref" 2>/dev/null || true
    git -C "$REPO_ROOT" worktree add "$workdir" "origin/$ref" 2>/dev/null || {
      # If it's a commit SHA
      git -C "$REPO_ROOT" worktree add --detach "$workdir" "$ref"
    }
  }

  log "Installing dependencies in $workdir..."
  (cd "$workdir" && yarn install --frozen-lockfile 2>/dev/null || yarn install)

  log "Building subgraph for network=$ETHEREUM_NETWORK..."
  (
    cd "$workdir"
    yarn prepare:"$ETHEREUM_NETWORK" 2>/dev/null || {
      warn "No prepare:$ETHEREUM_NETWORK script, trying generic prepare..."
      yarn prepare
    }
    yarn codegen
    yarn build
  )

  ok "Build complete for $ref"
}

deploy_subgraph() {
  local workdir="$1"

  log "Creating subgraph on graph-node..."
  curl -sf -X POST "$DEPLOY_URL" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"subgraph_create\",\"params\":{\"name\":\"$SUBGRAPH_NAME\"},\"id\":1}" \
    > /dev/null 2>&1 || true

  log "Deploying subgraph from $workdir..."
  (
    cd "$workdir"
    graph deploy "$SUBGRAPH_NAME" \
      --label "v0.0.1" \
      --ipfs "$IPFS_URL" \
      --node "$DEPLOY_URL" \
      --version-label "bench"
  )

  ok "Subgraph deployed"
}

# ─── Monitoring ──────────────────────────────────────────────────────────────

get_sync_status() {
  curl -sf "$STATUS_URL" \
    -H "Content-Type: application/json" \
    -d '{"query":"{ indexingStatuses { synced health chains { latestBlock { number } chainHeadBlock { number } } fatalError { message } } }"}' \
    2>/dev/null | jq -r '.data.indexingStatuses[0]' 2>/dev/null || echo "{}"
}

get_latest_block() {
  local status
  status=$(get_sync_status)
  echo "$status" | jq -r '.chains[0].latestBlock.number // "0"' 2>/dev/null || echo "0"
}

get_chain_head() {
  local status
  status=$(get_sync_status)
  echo "$status" | jq -r '.chains[0].chainHeadBlock.number // "0"' 2>/dev/null || echo "0"
}

is_synced() {
  local status
  status=$(get_sync_status)
  echo "$status" | jq -r '.synced // false' 2>/dev/null || echo "false"
}

has_fatal_error() {
  local status
  status=$(get_sync_status)
  local error
  error=$(echo "$status" | jq -r '.fatalError.message // empty' 2>/dev/null || echo "")
  [[ -n "$error" ]]
}

get_fatal_error() {
  local status
  status=$(get_sync_status)
  echo "$status" | jq -r '.fatalError.message // "unknown"' 2>/dev/null
}

wait_for_blocks() {
  local start_block target_block start_time current_block elapsed blocks_done bps eta

  log "Waiting for $TARGET_BLOCKS blocks to be indexed..."

  # Get the starting block (where indexing begins from)
  sleep 10  # give graph-node time to start indexing
  start_block=$(get_latest_block)

  if [[ "$start_block" == "0" || "$start_block" == "null" ]]; then
    # Wait a bit more for indexing to begin
    sleep 20
    start_block=$(get_latest_block)
  fi

  target_block=$((start_block + TARGET_BLOCKS))
  start_time=$(date +%s)

  log "Start block: $start_block, target block: $target_block"

  while true; do
    current_block=$(get_latest_block)
    elapsed=$(( $(date +%s) - start_time ))

    if has_fatal_error; then
      err "Subgraph encountered a fatal error: $(get_fatal_error)"
      return 1
    fi

    blocks_done=$((current_block - start_block))
    if [[ $blocks_done -gt 0 && $elapsed -gt 0 ]]; then
      bps=$(echo "scale=2; $blocks_done / $elapsed" | bc 2>/dev/null || echo "?")
      remaining=$((target_block - current_block))
      if [[ "$bps" != "?" && "$bps" != "0" ]]; then
        eta=$(echo "scale=0; $remaining / $bps" | bc 2>/dev/null || echo "?")
      else
        eta="?"
      fi
      log "Block $current_block / $target_block ($blocks_done indexed, ${bps} blocks/s, ETA: ${eta}s)"
    else
      log "Block $current_block / $target_block (warming up...)"
    fi

    if [[ $current_block -ge $target_block ]]; then
      ok "Target block reached in ${elapsed}s"
      echo "$elapsed"
      return 0
    fi

    sleep "$POLL_INTERVAL"
  done
}

# ─── Metrics Collection ─────────────────────────────────────────────────────

collect_postgres_metrics() {
  local label="$1"
  local output_file="$2"

  log "Collecting PostgreSQL metrics for '$label'..."

  cat > "$output_file" <<HEADER
# Benchmark Metrics: $label
# Collected at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Target blocks: $TARGET_BLOCKS
# Network: $ETHEREUM_NETWORK
HEADER

  # Total database size
  echo -e "\n## Database Size" >> "$output_file"
  psql "$PG_CONN" -t -A -c "
    SELECT pg_size_pretty(pg_database_size('graph-node')) AS total_db_size;
  " >> "$output_file" 2>/dev/null || warn "Could not query database size"

  # Per-schema sizes (subgraph deployments are stored in sgdN schemas)
  echo -e "\n## Schema Sizes" >> "$output_file"
  psql "$PG_CONN" -t -A -F'|' -c "
    SELECT
      schemaname AS schema,
      pg_size_pretty(sum(pg_total_relation_size(schemaname || '.' || tablename))) AS total_size,
      sum(pg_total_relation_size(schemaname || '.' || tablename)) AS total_bytes
    FROM pg_tables
    WHERE schemaname LIKE 'sgd%'
    GROUP BY schemaname
    ORDER BY total_bytes DESC;
  " >> "$output_file" 2>/dev/null || warn "Could not query schema sizes"

  # Per-table sizes
  echo -e "\n## Table Sizes" >> "$output_file"
  psql "$PG_CONN" -t -A -F'|' -c "
    SELECT
      schemaname || '.' || tablename AS table_name,
      pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename)) AS total_size,
      pg_total_relation_size(schemaname || '.' || tablename) AS total_bytes
    FROM pg_tables
    WHERE schemaname LIKE 'sgd%'
    ORDER BY pg_total_relation_size(schemaname || '.' || tablename) DESC
    LIMIT 30;
  " >> "$output_file" 2>/dev/null || warn "Could not query table sizes"

  # Entity counts per table
  echo -e "\n## Entity Counts" >> "$output_file"
  psql "$PG_CONN" -t -A -F'|' -c "
    SELECT
      schemaname || '.' || tablename AS table_name,
      (xpath('/row/cnt/text()',
        query_to_xml(format('SELECT count(*) AS cnt FROM %I.%I', schemaname, tablename), false, true, ''))
      )[1]::text::bigint AS row_count
    FROM pg_tables
    WHERE schemaname LIKE 'sgd%'
      AND tablename NOT LIKE 'poi2$%'
    ORDER BY table_name;
  " >> "$output_file" 2>/dev/null || warn "Could not query entity counts"

  # Total raw bytes (for comparison)
  echo -e "\n## Raw Totals" >> "$output_file"
  psql "$PG_CONN" -t -A -F'|' -c "
    SELECT
      sum(pg_total_relation_size(schemaname || '.' || tablename)) AS total_bytes,
      pg_size_pretty(sum(pg_total_relation_size(schemaname || '.' || tablename))) AS total_pretty
    FROM pg_tables
    WHERE schemaname LIKE 'sgd%';
  " >> "$output_file" 2>/dev/null || warn "Could not query raw totals"

  ok "Metrics saved to $output_file"
}

# ─── Comparison Report ───────────────────────────────────────────────────────

generate_report() {
  local base_metrics="$1"
  local compare_metrics="$2"
  local base_time="$3"
  local compare_time="$4"
  local report_file="$RESULTS_DIR/report-$(date +%Y%m%d-%H%M%S).md"

  log "Generating comparison report..."

  cat > "$report_file" <<EOF
# Subgraph Benchmark Report

**Date:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")
**Base ref:** \`$BASE_REF\`
**Compare ref:** \`$COMPARE_REF\`
**Network:** $ETHEREUM_NETWORK
**Blocks indexed:** $TARGET_BLOCKS

## Sync Time

| Version | Time (seconds) | Blocks/sec |
|---------|---------------|------------|
| Base (\`$BASE_REF\`) | ${base_time}s | $(echo "scale=2; $TARGET_BLOCKS / $base_time" | bc 2>/dev/null || echo "N/A") |
| Compare (\`$COMPARE_REF\`) | ${compare_time}s | $(echo "scale=2; $TARGET_BLOCKS / $compare_time" | bc 2>/dev/null || echo "N/A") |
EOF

  # Calculate time difference
  local time_diff pct_diff
  time_diff=$((compare_time - base_time))
  if [[ $base_time -gt 0 ]]; then
    pct_diff=$(echo "scale=1; ($time_diff * 100) / $base_time" | bc 2>/dev/null || echo "N/A")
    if [[ $time_diff -gt 0 ]]; then
      echo "| **Difference** | +${time_diff}s | **${pct_diff}% slower** |" >> "$report_file"
    elif [[ $time_diff -lt 0 ]]; then
      echo "| **Difference** | ${time_diff}s | **${pct_diff}% faster** |" >> "$report_file"
    else
      echo "| **Difference** | 0s | **No change** |" >> "$report_file"
    fi
  fi

  echo "" >> "$report_file"

  # Storage comparison
  local base_bytes compare_bytes
  base_bytes=$(grep -A1 "## Raw Totals" "$base_metrics" | tail -1 | cut -d'|' -f1 | tr -d ' ')
  compare_bytes=$(grep -A1 "## Raw Totals" "$compare_metrics" | tail -1 | cut -d'|' -f1 | tr -d ' ')

  if [[ -n "$base_bytes" && -n "$compare_bytes" && "$base_bytes" != "" && "$compare_bytes" != "" ]]; then
    local base_pretty compare_pretty storage_diff storage_pct
    base_pretty=$(grep -A1 "## Raw Totals" "$base_metrics" | tail -1 | cut -d'|' -f2 | tr -d ' ')
    compare_pretty=$(grep -A1 "## Raw Totals" "$compare_metrics" | tail -1 | cut -d'|' -f2 | tr -d ' ')
    storage_diff=$((compare_bytes - base_bytes))
    storage_pct=$(echo "scale=1; ($storage_diff * 100) / $base_bytes" | bc 2>/dev/null || echo "N/A")

    cat >> "$report_file" <<EOF
## Storage Size

| Version | Total Size | Raw Bytes |
|---------|-----------|-----------|
| Base (\`$BASE_REF\`) | $base_pretty | $base_bytes |
| Compare (\`$COMPARE_REF\`) | $compare_pretty | $compare_bytes |
| **Difference** | | **${storage_pct}%** |

EOF
  fi

  # Entity counts side by side
  cat >> "$report_file" <<EOF
## Entity Counts

### Base (\`$BASE_REF\`)
\`\`\`
$(grep -A1000 "## Entity Counts" "$base_metrics" | grep -B1000 "## Raw Totals" | head -n -1 | tail -n +2)
\`\`\`

### Compare (\`$COMPARE_REF\`)
\`\`\`
$(grep -A1000 "## Entity Counts" "$compare_metrics" | grep -B1000 "## Raw Totals" | head -n -1 | tail -n +2)
\`\`\`

## Table Sizes

### Base (\`$BASE_REF\`)
\`\`\`
$(grep -A1000 "## Table Sizes" "$base_metrics" | grep -B1000 "## Entity Counts" | head -n -1 | tail -n +2)
\`\`\`

### Compare (\`$COMPARE_REF\`)
\`\`\`
$(grep -A1000 "## Table Sizes" "$compare_metrics" | grep -B1000 "## Entity Counts" | head -n -1 | tail -n +2)
\`\`\`

---
*Generated by subgraph-benchmark*
EOF

  ok "Report saved to: $report_file"
  echo ""
  cat "$report_file"
}

# ─── Run a single benchmark ─────────────────────────────────────────────────

run_benchmark() {
  local ref="$1"
  local label="$2"
  local workdir="$SCRIPT_DIR/.worktree-$label"
  local metrics_file="$RESULTS_DIR/metrics-${label}.txt"

  log "━━━ Benchmarking: $ref ($label) ━━━"

  # Clean slate
  reset_infra

  # Build
  checkout_and_build "$ref" "$workdir"

  # Deploy
  deploy_subgraph "$workdir"

  # Wait for indexing
  local sync_time
  sync_time=$(wait_for_blocks)

  if [[ $? -ne 0 ]]; then
    err "Benchmark failed for $ref"
    # Clean up worktree
    git -C "$REPO_ROOT" worktree remove --force "$workdir" 2>/dev/null || true
    return 1
  fi

  # Collect metrics
  collect_postgres_metrics "$label" "$metrics_file"

  # Clean up worktree
  git -C "$REPO_ROOT" worktree remove --force "$workdir" 2>/dev/null || true

  # Return sync time
  echo "$sync_time" > "$RESULTS_DIR/time-${label}.txt"

  ok "Benchmark complete for $ref: ${sync_time}s"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  check_deps

  mkdir -p "$RESULTS_DIR"

  log "╔══════════════════════════════════════════════════╗"
  log "║         Subgraph Benchmark Tool                  ║"
  log "╚══════════════════════════════════════════════════╝"
  log ""
  log "Base ref:     $BASE_REF"
  log "Compare ref:  $COMPARE_REF"
  log "Network:      $ETHEREUM_NETWORK"
  log "Target blocks: $TARGET_BLOCKS"
  log "RPC:          ${ETHEREUM_RPC:0:50}..."
  log ""

  # Run base benchmark
  run_benchmark "$BASE_REF" "base"
  local base_time
  base_time=$(cat "$RESULTS_DIR/time-base.txt")

  # Run compare benchmark
  run_benchmark "$COMPARE_REF" "compare"
  local compare_time
  compare_time=$(cat "$RESULTS_DIR/time-compare.txt")

  # Stop infra
  stop_infra

  # Generate report
  generate_report \
    "$RESULTS_DIR/metrics-base.txt" \
    "$RESULTS_DIR/metrics-compare.txt" \
    "$base_time" \
    "$compare_time"
}

# Run if not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap 'stop_infra 2>/dev/null; git -C "$REPO_ROOT" worktree remove --force "$SCRIPT_DIR/.worktree-base" 2>/dev/null; git -C "$REPO_ROOT" worktree remove --force "$SCRIPT_DIR/.worktree-compare" 2>/dev/null' EXIT
  main
fi
