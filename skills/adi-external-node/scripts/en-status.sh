#!/usr/bin/env bash
# en-status.sh: read-only health snapshot of an ADI external node.
#
# Answers the two questions an operator actually has:
#   1. Is the node up and serving RPC?
#   2. Is it catching up, caught up, or stuck?
#
# Never mutates anything: no docker commands beyond `ps`, no writes to the
# data directory, no restarts. Safe to run at any time, including while
# the node is syncing.
#
# Dependencies: bash, curl, docker (all present on any machine running the
# node). jq and python are deliberately not required.
#
# Usage:
#   ./en-status.sh                 # auto-detect everything
#   ./en-status.sh --sample 10     # sample block rate over 10s instead of 5s
#
# Environment overrides (only needed when auto-detection is not enough):
#   ADI_NODE_RPC         node JSON-RPC          (default http://localhost:3050)
#   ADI_NODE_STATUS      node status server     (default http://localhost:3071)
#   ADI_NODE_PROM        node prometheus        (default http://localhost:3312)
#   ADI_NODE_TARGET_RPC  network reference RPC  (default: per detected network)
#   ADI_DATA_DIR         chain data directory   (default: from the container)
#
# Exit codes: 0 healthy or syncing normally, 1 degraded (needs a look),
#             2 node down or unreachable.

set -uo pipefail

SAMPLE=5
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sample) SAMPLE="${2:-5}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
done

RPC="${ADI_NODE_RPC:-http://localhost:3050}"
STATUS="${ADI_NODE_STATUS:-http://localhost:3071}"
PROM="${ADI_NODE_PROM:-http://localhost:3312}"
DATA_DIR="${ADI_DATA_DIR:-}"

REF_RPC_MAINNET="https://rpc.adifoundation.ai"
REF_RPC_TESTNET="https://rpc.ab.testnet.adifoundation.ai"

TIMEOUT=5

say()  { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }

# http_get <url> -> body on stdout, empty on any failure.
http_get() {
  curl -fsS -m "$TIMEOUT" "$1" 2>/dev/null
}

# rpc <url> <method> -> JSON body, empty on failure.
rpc() {
  curl -fsS -m "$TIMEOUT" -X POST "$1" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"$2\",\"params\":[],\"id\":1}" 2>/dev/null
}

# eth_blockNumber <url> -> decimal block number, empty on failure.
eth_block() {
  local body
  body="$(rpc "$1" eth_blockNumber)" || return 1
  local hex
  hex="$(printf '%s' "$body" | sed -n 's/.*"result"[[:space:]]*:[[:space:]]*"\(0x[0-9a-fA-F]*\)".*/\1/p')"
  [[ -n "$hex" ]] || return 1
  printf '%d' "$((hex))"
}

say "== containers =="
NETWORK=""
CONTAINER_STATUS=""
STOPPED_CONTAINER=""
if command -v docker >/dev/null 2>&1; then
  PS="$(docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null)"
  if [[ -z "$PS" ]]; then
    note "docker ps returned nothing (daemon down, or no containers running)"
  else
    while IFS=$'\t' read -r name image status; do
      [[ -n "$name" ]] || continue
      case "$name" in
        adi_*_external_node|*_external_node)
          note "$name  $status  [$image]"
          CONTAINER_STATUS="$status"
          NETWORK="$(printf '%s' "$name" | sed -n 's/^adi_\([a-z0-9]*\)_external_node$/\1/p')"
          ;;
        *)
          note "$name  $status"
          ;;
      esac
    done <<< "$PS"
  fi

  # A stopped-but-present node is a different situation from "nothing here".
  # Look for it so the verdict can say which, and so the network is still
  # known (the reference RPC depends on it).
  if [[ -z "$CONTAINER_STATUS" ]]; then
    STOPPED_RAW="$(docker ps -a --format '{{.Names}}\t{{.Status}}' 2>/dev/null | grep -E '_external_node' | head -1)"
    if [[ -n "$STOPPED_RAW" ]]; then
      STOPPED_CONTAINER="$(printf '%s' "$STOPPED_RAW" | cut -f1)"
      note "$STOPPED_RAW  (stopped)"
      NETWORK="$(printf '%s' "$STOPPED_CONTAINER" | sed -n 's/^adi_\([a-z0-9]*\)_external_node$/\1/p')"
    fi
  fi
else
  note "docker not found; relying on HTTP probes only"
fi
[[ -n "$NETWORK" ]] || NETWORK="mainnet"

REF_RPC="${ADI_NODE_TARGET_RPC:-}"
if [[ -z "$REF_RPC" ]]; then
  if [[ "$NETWORK" == "testnet" ]]; then REF_RPC="$REF_RPC_TESTNET"; else REF_RPC="$REF_RPC_MAINNET"; fi
fi

say
say "== node RPC ($RPC) =="
HEAD="$(eth_block "$RPC")"
if [[ -z "$HEAD" ]]; then
  note "unreachable: the node is not serving JSON-RPC"
else
  note "head block: $HEAD"
  SYNCING="$(rpc "$RPC" eth_syncing | sed -n 's/.*"result"[[:space:]]*:[[:space:]]*\([^},]*\).*/\1/p')"
  [[ -n "$SYNCING" ]] && note "eth_syncing: $SYNCING"
fi

say
say "== reference RPC ($NETWORK) =="
TARGET="$(eth_block "$REF_RPC")"
if [[ -z "$TARGET" ]]; then
  note "$REF_RPC unreachable: cannot compute lag"
else
  note "target block: $TARGET"
fi

RATE=""
if [[ -n "$HEAD" && -n "$TARGET" ]]; then
  LAG=$((TARGET - HEAD))
  note "lag: $LAG blocks"
  sleep "$SAMPLE"
  HEAD2="$(eth_block "$RPC")"
  if [[ -n "$HEAD2" && "$HEAD2" -ge "$HEAD" ]]; then
    GAINED=$((HEAD2 - HEAD))
    note "advanced: $GAINED blocks in ${SAMPLE}s"
    [[ "$GAINED" -gt 0 ]] && RATE="$GAINED"
  fi
fi

say
say "== peers and pipeline =="
PEERS=""
PROM_BODY="$(http_get "$PROM/metrics")"
if [[ -n "$PROM_BODY" ]]; then
  # Metric renamed network.connected_peers -> network_connected_peers in v0.20.12.
  PEERS="$(printf '%s\n' "$PROM_BODY" | sed -n 's/^network[._]connected_peers[^ ]* \([0-9][0-9]*\).*/\1/p' | head -1)"
  note "connected peers: ${PEERS:-unknown}"
else
  note "prometheus unreachable at $PROM"
fi

HEALTH="$(http_get "$STATUS/status/health")"
if [[ -n "$HEALTH" ]]; then
  note "health: $(printf '%s' "$HEALTH" | tr -d '\n' | cut -c1-200)"
else
  note "status server unreachable at $STATUS"
fi

PIPELINE="$(http_get "$STATUS/status/pipeline")"
if [[ -n "$PIPELINE" ]]; then
  MAXLAG="$(printf '%s' "$PIPELINE" | tr ',' '\n' | sed -n 's/.*"block_diff":\([0-9]*\).*/\1/p' | sort -n | tail -1)"
  [[ -n "$MAXLAG" ]] && note "pipeline max lag: $MAXLAG blocks"
fi

say
say "== disk =="
if [[ -z "$DATA_DIR" && -n "$CONTAINER_STATUS" ]]; then
  NODE_CONTAINER="$(docker ps --format '{{.Names}}' 2>/dev/null | sed -n 's/^\(adi_.*_external_node\)$/\1/p' | head -1)"
  if [[ -n "$NODE_CONTAINER" ]]; then
    DATA_DIR="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/chain"}}{{.Source}}{{end}}{{end}}' "$NODE_CONTAINER" 2>/dev/null)"
  fi
fi
if [[ -n "$DATA_DIR" && -d "$DATA_DIR" ]]; then
  note "data dir: $DATA_DIR"
  DF="$(df -Pk "$DATA_DIR" 2>/dev/null | sed -n '2p')"
  if [[ -n "$DF" ]]; then
    note "$(printf '%s' "$DF" | awk '{printf "filesystem %s: %d GiB used of %d GiB (%s)", $1, $3/1048576, $2/1048576, $5}')"
  fi
  SIZE="$(du -sh "$DATA_DIR" 2>/dev/null | cut -f1)"
  [[ -n "$SIZE" ]] && note "chain data size: $SIZE"
else
  note "data dir not determined (pass ADI_DATA_DIR)"
fi

say
say "== verdict =="
if [[ -z "$HEAD" ]]; then
  if [[ -n "$CONTAINER_STATUS" ]]; then
    say "DEGRADED: container is running ($CONTAINER_STATUS) but RPC is not answering yet."
    note "A node that just started takes minutes before RPC serves. If it has been longer, check: docker logs --tail 100 <container>"
    exit 1
  fi
  if [[ -n "$STOPPED_CONTAINER" ]]; then
    say "STOPPED: $STOPPED_CONTAINER exists but is not running."
    note "Start it: cd <setup-repo> && ./external-node.sh [--testnet] start --l1-rpc-url <archive-l1-rpc>"
    note "Reuse the saved P2P secret key, or the node resyncs from scratch."
    exit 2
  fi
  say "DOWN: no external node container on this machine and no RPC."
  note "The node may never have been installed here, or it runs under a different container name."
  exit 2
fi

if [[ -z "$TARGET" ]]; then
  say "UNKNOWN: node RPC is up but the reference RPC is unreachable; lag cannot be computed."
  exit 1
fi

if [[ -n "$PEERS" && "$PEERS" -eq 0 ]]; then
  say "DEGRADED: no P2P peers. The node depends on peers (or the main node) to receive blocks."
  note "Check that outbound TCP+UDP 3060 is allowed and that boot nodes are configured."
  exit 1
fi

if [[ "$LAG" -le 5 ]]; then
  say "HEALTHY: caught up (lag $LAG blocks)."
  exit 0
fi

if [[ -n "$RATE" ]]; then
  ETA=""
  MINUTES=$(( LAG * SAMPLE / RATE / 60 ))
  [[ "$MINUTES" -gt 0 ]] && ETA="; at the current rate, roughly ${MINUTES} min to catch up"
  say "SYNCING: $LAG blocks behind, head advancing${ETA}."
  note "A full replay from genesis takes hours. This is normal on a fresh node."
  exit 0
fi

say "STALLED: $LAG blocks behind and the head did not advance in ${SAMPLE}s."
note "If the node started recently it may still be replaying; watch the logs for 'Replay block' lines."
note "If it stays flat, check the broken-signal list in references/troubleshooting.md."
exit 1
