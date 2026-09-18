# ADI external node: network and upgrade reference

## Networks

| | mainnet | testnet |
|---|---|---|
| Chain ID | 36900 (`0x9024`) | 99999 (`0x1869f`) |
| Reference RPC | `https://rpc.adifoundation.ai` | `https://rpc.ab.testnet.adifoundation.ai` |
| Container prefix | `adi_mainnet` | `adi_testnet` |
| Default data dir | `./mainnet_data` | `./testnet_data` |
| Setup script flag | (default) | `--testnet` |

Chain IDs and RPC endpoints verified against the live networks (`eth_chainId`, 2026-09). The node's own client version is reported by `web3_clientVersion`. Mainnet currently answers `zksync-os/v0.21.1` on the main node, while the published external node image is `v0.20.12-b1`. Those numbers differ and that is expected: the main node and the external node are separate builds.

## Ports

| Port | Protocol | Service |
|---|---|---|
| 3050 | TCP | JSON-RPC (`rpc_address`) |
| 3060 | TCP + UDP | P2P devp2p (`network_port`), v0.20.12 and later |
| 3071 | TCP | status server (`status_server_address`) |
| 3312 | TCP | Prometheus metrics (`observability_prometheus_port`) |
| 3054 | TCP | **removed**, HTTP replay, v0.13.0 only |

Both TCP and UDP 3060 must be reachable outbound. If a firewall allows only one of the two, the node may boot but never peer.

## Versions

| Version | Transport | Compose layout |
|---|---|---|
| `v0.13.0-b4` and earlier | HTTP replay via `replay.adifoundation.ai` + `proof-sync` sidecar | includes `proof-sync`, `cloudflared-tcp-proxy`, port 3054 |
| `v0.20.12-b1` (what the setup repo pins) | P2P (`network_enabled=true`, port 3060) | no sidecars, no proof storage; requires `network_secret_key` and `network_boot_nodes` |

The pin in whichever checkout you run is the authoritative answer for what the EN should be. Treat the table above as orientation, not as a live fact: read the running image tag and the repo pin on the machine in front of you.

Env vars removed in v0.20.12: `sequencer_block_replay_download_address`, `sequencer_block_replay_server_address`, `prover_api_object_store_*`, `l1_sender_pubdata_mode`. `general_l1_rpc_url` was renamed to `l1_provider_rpc_url` (the `GENERAL_L1_RPC_URL` env var keeps working). ENs stopped using proof storage entirely; the `proof-sync` container in an older checkout is legacy.

### Two different version numbers, and why they never match

The image tag and the RPC version answer come from the same build but are formatted differently. This trips people up constantly, so read it once:

| Where | Example | What it is |
|---|---|---|
| Image tag (`docker ps`, compose `EN_VERSION`) | `v0.20.12-b1` | release tag, includes a build suffix `-bN` |
| `web3_clientVersion` on the node's RPC | `zksync-os/v0.20.12` | semver from the binary's `Cargo.toml`, **no build suffix** |

The node compiles `NODE_CLIENT_VERSION` from `CARGO_PKG_VERSION_MAJOR/MINOR/PATCH` and deliberately drops prerelease and build metadata. So `v0.20.12-b1` reports `zksync-os/v0.20.12`, and `v0.20.12-b4` reports the *same* string. Identical `web3_clientVersion` does not mean identical build.

Compare them as `major.minor.patch` only. A different patch version is a real difference; a missing `-bN` is not.

### Checking whether a version move is real

Three signals, none sufficient alone:

```bash
# What is running here (image tag)
docker ps --format '{{.Image}}' | grep external_node

# What this checkout wants, and whether upstream has moved past it
cd ~/ADI-Stack-EN-Setup-script && git fetch --quiet origin
grep -o 'EN_VERSION:-[^}]*' docker-compose.<network>.yml          # working tree: what you would deploy
git show origin/main:docker-compose.<network>.yml | grep -o 'EN_VERSION:-[^}]*'   # upstream: what is current
git rev-list --count HEAD..origin/main                            # 0 means the checkout is current

# What the node binary reports, on your node and on the main node
curl -s -X POST http://localhost:3050 -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"web3_clientVersion","params":[],"id":1}'
curl -s -X POST https://rpc.adifoundation.ai -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"web3_clientVersion","params":[],"id":1}'
```

Read the working-tree file *and* `origin/main`: they differ whenever the checkout is behind, and a stale checkout reports an old version as if it were current. A working tree that is behind upstream is exactly the situation the upgrade path exists to fix.

What each tells you:

- **Repo tag newer than the running image** means an upgrade exists in the repo. It does not mean the network is ready for it.
- **Main node RPC version** is a live signal of what the cluster runs, but it does not track the EN image numbering. Main nodes report internal releases that were never pinned as EN images (mainnet currently answers `zksync-os/v0.21.1` while the setup repo pins the EN at `v0.20.12-b1`). Use it to detect that the cluster has moved past your node, not to derive the image tag you should be on.
- **The repo pin decides what the EN should run.** Version tags live in `ADI-Foundation-Labs/ADI-Stack-Server` (`v0.20.12-bN`, `v0.21.0-bN`); the EN setup repo's compose pin selects which of them the external node uses.

Practical rule: if the main node's `major.minor.patch` is ahead of your node's `web3_clientVersion`, the cluster has moved and an EN upgrade is likely coming or live. Confirm against the repo pin and the `upgrades/` guide before acting.

Not available: the container registry (`harbor.sde.adifoundation.ai`) requires authentication for tag listing and manifest reads, so you cannot enumerate published image tags anonymously. The repo compose pin is the supported way to learn which image is intended.

When the signals disagree and you cannot resolve it, that is the point to ask the operator. Do not upgrade on a repo tag alone.

## Boot nodes

`BOOT_NODE_URLS` falls back to these per-network defaults (from `external-node.sh` in the setup repo):

- mainnet: `enode://0x433c50a2c2b4091330edff3bde14be9913f7fcde35c5267f3b2281b7031923518b18f3c99b83bf5edb2dbe708d9ec119cceaf4012f5f601525beaf9c564dd57a@74.162.154.230:3060`
- testnet: `enode://0x89317fb81e979bd5b0d102f2c3da3ccb569cf2b2802fb0c3af562b625b1d695dc44b5c6ef3848697dce61e6cc9a8f9fe6ad89ff08cfb2ab4e51bc7a55986ee6f@20.233.0.124:3060`

Only override these if ADI publishes replacements; a stale boot node is the usual cause of a node that runs but never finds peers.

## Upgrade: v0.13.0 → v0.20.12

The one breaking change operators hit. Full checklist lives in the setup repo (`upgrades/v0.13.0_to_v0.20.12.md`); this is the operational short form.

**Preconditions**

- The main node is on v0.20.12 (confirm it has moved before upgrading yours). Coordinated upgrade: old and new nodes do not peer, and their verification transport is incompatible.
- The v0.13.0 node is stopped.
- The existing P2P secret key is at hand (or will be generated on first start).

**Steps**

1. Stop: `./external-node.sh stop`, confirm with `./external-node.sh status`.
2. Pull the repo: `git pull origin main`. This brings the new compose, the new genesis (with `execution_version` removed), and the v0.20.12 image tag. Local compose edits will block the pull; the CLI and the script both treat a diverged checkout as a hard error rather than merging.
3. Delete legacy variables from any local `.env` or override file: the `sequencer_block_replay_*`, `prover_api_object_store_*`, and `l1_sender_pubdata_mode` entries.
4. Port changes: drop 3054, add 3060 TCP **and** UDP.
5. Pull the image: `./external-node.sh pull`.
6. Start with the L1 RPC and (on restarts) the saved key: `./external-node.sh start --l1-rpc-url <archive-l1-rpc> --external-network-secret-key <saved-key>`
7. Verify: `resolved external IP (STUN)` and `Connected to peer <id>` in the logs, `Replay block` progressing, `scripts/en-status.sh` reporting `SYNCING` or `HEALTHY`, and no `verifier authorization failures`.

The `proof-sync` container and the `cloudflared-tcp-proxy` service are removed by the new compose. If they still appear in `docker ps`, the stack was recreated from the old compose (usually a checkout that was not pulled).

## Version-specific notes

- **v0.20.12 changed two logging defaults**: `observability_log_format` is now `json` and color is off. Logs are still greppable, but expect JSON lines.
- **`sequencer_revm_consistency_checker_enabled`** flipped to `true`; it can be disabled for faster local startup.
- **The CLI (`adi-node`) alternative.** If the operator has the `adi-node` binary installed, `adi-node health`, `status`, and `upgrade` perform the same operations with more automation (it detects the running node, persists the key, and refuses to upgrade a dirty checkout). Prefer it when present; this skill is the path when only Docker and the setup script are available.

## Where things live

| Item | Path |
|---|---|
| Setup repo | `~/ADI-Stack-EN-Setup-script` (or `ADI_EN_SETUP_DIR`) |
| Compose file | `<repo>/docker-compose.<network>.yml` |
| Chain data | `<repo>/<network>_data` → mounted at `/chain` |
| RocksDB state | `.../db/node1` |
| Genesis | `<repo>/genesis/<network>.json` → `/genesis/genesis.json` |
| Operator state (CLI only) | `~/.adi-node/state.json` (holds the secret key; `0600`) |
