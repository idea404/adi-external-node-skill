---
name: adi-external-node
description: Operates and monitors an ADI Chain external node running on this machine — start, stop, upgrade to a new EN version, and diagnose sync/health problems. Use when the user mentions an ADI external node, adi_mainnet_external_node or adi_testnet_external_node containers, external-node.sh, "node is not syncing", "node is behind", upgrading the ADI node, or checking whether an ADI node is healthy.
license: MIT
compatibility: Requires docker with the compose plugin, git, and outbound network access. Assumes the ADI-Stack-EN-Setup-script checkout and the running external_node container.
metadata:
  author: ADI-Foundation-Labs
  version: "1.0"
---

# ADI external node

An ADI external node (`external_node` container) replays L2 blocks from the ADI
main node, keeps local state, and serves JSON-RPC, status, and metrics. It does
not validate blocks, produce blocks, or take part in consensus. Almost every
"the node is broken" report is either normal initial sync, a pruned L1 RPC, or
a missing P2P boot node.

## Ground rules

Read these before touching anything.

1. **Never delete or "reset" the chain data directory.** `<network>_data` holds
   the RocksDB state and the node's P2P identity. Deleting it forces a full
   resync from genesis (hours). There is no scenario in this skill where
   removing it is the right first move.
2. **Never regenerate the network secret key on a running node.** The key is
   the node's P2P identity. Losing it means a full resync. The setup script
   auto-generates and prints one on first start; that value must be reused.
3. **Upgrades are coordinated and network-wide.** Nodes on different versions
   do not peer with each other and their batch verification transport is
   incompatible. Only upgrade after ADI announces the main node is upgraded.
   Upgrading early leaves the node unable to sync.
4. **Verify before acting.** Run `scripts/en-status.sh` first; it is read-only.
   Prefer read-only diagnosis until you can name the fault.
5. **Do not run `external-node.sh down` or `docker compose down` to "restart"
   a node** unless a stop is genuinely what is wanted: `down` removes the
   containers. `stop` preserves them.

## Identify what is running here

```bash
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
```

| What you see | Meaning |
|---|---|
| `adi_mainnet_external_node` | mainnet node, chain ID 36900 |
| `adi_testnet_external_node` | testnet node, chain ID 99999 |
| `adi_<net>_proof_sync` | **legacy** (v0.13.0 layout). Present ⇒ node predates the P2P upgrade |
| image tag `…:v0.20.12-b1` | current version (P2P), ports 3050/3060/3071/3312 |
| image tag `…:v0.13.0-b4` | old version (HTTP replay), ports 3050/3054/3071/3312 |

Network defaults, ports, data directories, and the upgrade mechanics are in
[references/network.md](references/network.md). Read it before any upgrade.

## Health check

```bash
scripts/en-status.sh              # read-only, ~5s
scripts/en-status.sh --sample 15  # longer sample for a slow-syncing node
```

It prints containers, head block, lag vs the network reference, block rate,
P2P peers, pipeline lag, and disk usage, then a verdict:

| Verdict | Exit | Meaning |
|---|---|---|
| `HEALTHY` | 0 | caught up (≤5 blocks) |
| `SYNCING` | 0 | behind but the head is advancing — normal, leave it alone |
| `STALLED` | 1 | behind, head not advancing in the sample window |
| `DEGRADED` | 1 | up but no P2P peers, or RPC not answering yet |
| `DOWN` | 2 | no container, no RPC |
| `UNKNOWN` | 1 | node up, reference RPC unreachable |

Raw probes, if the script is not usable:

```bash
# node head vs the network reference
curl -s -X POST http://localhost:3050 -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
curl -s -X POST https://rpc.adifoundation.ai -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# caught up? (false = yes)
curl -s -X POST http://localhost:3050 -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}'

# process health (NOT sync state)
curl -s http://localhost:3071/status/health
curl -s http://localhost:3071/status/pipeline

# peers and P2P state
curl -s http://localhost:3312/metrics | grep -E 'connected_peers'
docker logs --tail 200 adi_mainnet_external_node 2>&1 | grep -E 'Connected to peer|resolved external IP|Replay block'
```

### The trap: L1 watcher height is not node height

`zksync_os_l1_watcher` log lines (`discovered executed batch N`, `last_executed_block M`,
`frontier normal`) describe L1's view of executed batches. They say nothing
about how far this node has replayed L2. A node can show a healthy, advancing
L1 watcher and still be hours from tip. Judge sync progress by
`eth_blockNumber` against the reference RPC, never by watcher logs.

### Decision rule

Fresh start + head advancing + RPC serving = **syncing, let it finish**. Full
replay from genesis takes hours; a node that started recently is not broken.
Only escalate to fault-finding when the head is flat *and* one of these is
true:

- `eth_syncing` frozen at the same `currentBlock` for a long stretch
- repeated panics / restarts, `verifier authorization failures`,
  `missing VerifyBatchResult`
- zero peers and no `Connected to peer` lines

Diagnosis table for each fault: [references/troubleshooting.md](references/troubleshooting.md).

## Operating the node

The node is managed with the `ADI-Stack-EN-Setup-script` checkout
(default `~/ADI-Stack-EN-Setup-script`). All commands take `--testnet` for the
test network; mainnet is the default.

```bash
cd ~/ADI-Stack-EN-Setup-script

./external-node.sh status        # compose ps
./external-node.sh logs          # follow all services
./external-node.sh stop          # stop, containers preserved
./external-node.sh start --l1-rpc-url <archive-l1-rpc>   # (re)start
./external-node.sh pull          # fetch newer images for the current version
```

Start requirements:

- `--l1-rpc-url` (or `GENERAL_L1_RPC_URL`) is required, and it must be an
  **archive-capable** Ethereum L1 RPC. A pruned endpoint makes the node panic
  at startup with `state at block is pruned`.
- `EXTERNAL_NETWORK_SECRET_KEY` — reuse the saved value on every restart. If
  the operator has it, pass `--external-network-secret-key <key>`. If nobody
  has it, do not invent one on an existing node: first check the logs and any
  ops notes for the auto-generated value.
- `BOOT_NODE_URLS` — falls back to the per-network default.

## Upgrading

An upgrade is a coordinated, network-wide event. Follow
[references/network.md](references/network.md) for the full sequence and the
version-specific steps; the shape is always:

1. **Confirm ADI has announced the main node is on the new version.** If not
   announced, stop here. Upgrading early means no peering and no sync.
2. Snapshot state: current image tag, `external-node.sh status`, and the saved
   secret key.
3. Stop the node (`./external-node.sh stop`).
4. `git pull` the setup repo, then `./external-node.sh pull`.
5. Recreate: `./external-node.sh start --l1-rpc-url …` with the **same**
   secret key. Compose files are the source of truth for env changes between
   versions; the version bump is a repo change, not a manual edit.
6. Verify per the health section: RPC up, head advancing, peers > 0, and no
   `verifier authorization failures` in the logs.

Rollback, if the node will not come back: stop, `git checkout <previous tag>`
in the setup repo, `pull`, `start` again with the same secret key. The data
directory and key are never touched by this, so it returns to the prior state.

## Files in this skill

- `scripts/en-status.sh` — read-only health snapshot with a verdict.
- `references/network.md` — networks, ports, versions, upgrade steps.
- `references/troubleshooting.md` — symptom → cause → action.
