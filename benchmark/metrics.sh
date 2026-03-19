#!/usr/bin/env bash
#
# Quick metrics snapshot for a running subgraph deployment.
#
# Usage:
#   ./metrics.sh              # Print metrics to stdout
#   ./metrics.sh --json       # Output as JSON (for scripting)
#
# Requires: psql, curl, jq

set -euo pipefail

PG_CONN="${PG_CONN:-postgresql://graph-node:let-me-in@127.0.0.1:5432/graph-node}"
STATUS_URL="${STATUS_URL:-http://127.0.0.1:8030/graphql}"
JSON_MODE=false

if [[ "${1:-}" == "--json" ]]; then
  JSON_MODE=true
fi

# ─── Sync Status ─────────────────────────────────────────────────────────────

sync_status=$(curl -sf "$STATUS_URL" \
  -H "Content-Type: application/json" \
  -d '{"query":"{ indexingStatuses { subgraph synced health chains { latestBlock { number hash } chainHeadBlock { number } earliestBlock { number } } fatalError { message } } }"}' \
  2>/dev/null || echo '{"data":{"indexingStatuses":[]}}')

latest_block=$(echo "$sync_status" | jq -r '.data.indexingStatuses[0].chains[0].latestBlock.number // "N/A"')
chain_head=$(echo "$sync_status" | jq -r '.data.indexingStatuses[0].chains[0].chainHeadBlock.number // "N/A"')
earliest_block=$(echo "$sync_status" | jq -r '.data.indexingStatuses[0].chains[0].earliestBlock.number // "N/A"')
synced=$(echo "$sync_status" | jq -r '.data.indexingStatuses[0].synced // "N/A"')
health=$(echo "$sync_status" | jq -r '.data.indexingStatuses[0].health // "N/A"')
fatal_error=$(echo "$sync_status" | jq -r '.data.indexingStatuses[0].fatalError.message // ""')

# ─── Database Metrics ────────────────────────────────────────────────────────

db_size=$(psql "$PG_CONN" -t -A -c "SELECT pg_size_pretty(pg_database_size('graph-node'));" 2>/dev/null || echo "N/A")
db_size_bytes=$(psql "$PG_CONN" -t -A -c "SELECT pg_database_size('graph-node');" 2>/dev/null || echo "0")

# Subgraph storage (sgd schemas only)
sgd_size=$(psql "$PG_CONN" -t -A -c "
  SELECT COALESCE(pg_size_pretty(sum(pg_total_relation_size(schemaname || '.' || tablename))), 'N/A')
  FROM pg_tables WHERE schemaname LIKE 'sgd%';
" 2>/dev/null || echo "N/A")

sgd_size_bytes=$(psql "$PG_CONN" -t -A -c "
  SELECT COALESCE(sum(pg_total_relation_size(schemaname || '.' || tablename)), 0)
  FROM pg_tables WHERE schemaname LIKE 'sgd%';
" 2>/dev/null || echo "0")

# Entity counts
entity_counts=$(psql "$PG_CONN" -t -A -F'|' -c "
  SELECT
    tablename,
    (xpath('/row/cnt/text()',
      query_to_xml(format('SELECT count(*) AS cnt FROM %I.%I', schemaname, tablename), false, true, ''))
    )[1]::text::bigint AS row_count
  FROM pg_tables
  WHERE schemaname LIKE 'sgd%'
    AND tablename NOT LIKE 'poi2$%'
  ORDER BY row_count DESC;
" 2>/dev/null || echo "")

total_entities=$(echo "$entity_counts" | awk -F'|' '{s+=$2} END {print s+0}')

# ─── Output ──────────────────────────────────────────────────────────────────

if $JSON_MODE; then
  entities_json="{"
  first=true
  while IFS='|' read -r table count; do
    [[ -z "$table" ]] && continue
    if ! $first; then entities_json+=","; fi
    entities_json+="\"$table\":$count"
    first=false
  done <<< "$entity_counts"
  entities_json+="}"

  cat <<EOF
{
  "sync": {
    "latest_block": "$latest_block",
    "chain_head": "$chain_head",
    "earliest_block": "$earliest_block",
    "synced": $synced,
    "health": "$health",
    "fatal_error": "$fatal_error"
  },
  "storage": {
    "database_size": "$db_size",
    "database_size_bytes": $db_size_bytes,
    "subgraph_size": "$sgd_size",
    "subgraph_size_bytes": $sgd_size_bytes
  },
  "entities": {
    "total": $total_entities,
    "by_table": $entities_json
  }
}
EOF
else
  echo "═══════════════════════════════════════════"
  echo "  Subgraph Metrics Snapshot"
  echo "═══════════════════════════════════════════"
  echo ""
  echo "  Sync Status"
  echo "  ───────────"
  echo "  Health:         $health"
  echo "  Synced:         $synced"
  echo "  Latest block:   $latest_block"
  echo "  Chain head:     $chain_head"
  echo "  Earliest block: $earliest_block"
  if [[ -n "$fatal_error" ]]; then
    echo "  FATAL ERROR:    $fatal_error"
  fi
  echo ""
  echo "  Storage"
  echo "  ───────"
  echo "  Database total: $db_size"
  echo "  Subgraph data:  $sgd_size"
  echo ""
  echo "  Entity Counts (total: $total_entities)"
  echo "  ─────────────"
  while IFS='|' read -r table count; do
    [[ -z "$table" ]] && continue
    printf "  %-40s %s\n" "$table" "$count"
  done <<< "$entity_counts"
  echo ""
  echo "═══════════════════════════════════════════"
fi
