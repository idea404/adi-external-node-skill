# ADI external node: troubleshooting

Symptom → cause → action. Check the read-only diagnosis before changing anything: `scripts/en-status.sh`.

## Node is at height 0 / "Unable to obtain node height"

**Cause:** normal on a fresh node. The RPC does not serve an L2 head until replay has progressed.

**Action:** wait. Confirm progress with `Replay block` lines in the logs and a rising `eth_blockNumber`. A full replay takes hours. Do not restart the node to "fix" this. Each restart restarts the replay from where it left off, and repeated restarts make it take longer, not shorter.

## Behind, and not catching up

Distinguish the two cases before acting:

| Observation | Reading |
|---|---|
| `discovered executed batch` / `last_executed_block` climbing, `frontier normal` | L1 watcher healthy. The remaining work is L2 replay (normal) |
| `Replay block #N` lines appearing steadily | Replay is progressing |
| `eth_syncing` returns a `currentBlock` that never changes | genuinely stuck |
| No new log lines of any kind for a long stretch | stalled, investigate |

**Action when stalled:** `docker logs --tail 200 adi_mainnet_external_node`. Look for panics, `verifier authorization failures`, or `missing VerifyBatchResult`. Those are real faults, not sync lag. If the logs are clean and simply quiet, check peers; a node with no peers cannot receive blocks.

## No P2P peers

```bash
# works on both spellings: v0.13 network.connected_peers, v0.20.12 network_connected_peers
curl -s http://localhost:3312/metrics | grep -E 'network[._]connected_peers'
docker logs --tail 200 adi_mainnet_external_node | grep -E 'Connected to peer|resolved external IP'
```

**Causes, in likelihood order:**

1. **Firewall blocks 3060.** Both TCP *and* UDP must be open. Verify outbound from the host: `nc -zv 74.162.154.230 3060` (mainnet boot node). No `resolved external IP (STUN)` in the logs points here too.
2. **Boot nodes missing or wrong.** `network_boot_nodes` must be non-empty. `external-node.sh` supplies the network default; a hand-written compose file must set `BOOT_NODE_URLS` itself. Values: [network.md](network.md).
3. **Version mismatch.** A v0.13.0 node cannot peer with a v0.20.12 network. Check the image tag; if the network already upgraded, the node must too.
4. **Port already taken** by an old container still bound to 3060. Check with `docker ps -a` for stopped-but-not-removed containers.

### A low peer count is expected, and the number is not a health target

The P2P network is in a transitional stage: traffic is exchanged with the central sequencer, not a full peer mesh. ADI has stated that full-fledged P2P is still in progress, so `network_connected_peers 1` is a normal, healthy reading. Do not diagnose on a low peer count alone, and do not expect the count to climb with more boot nodes.

What actually matters is whether blocks are arriving, which the sync verdict already answers.

### Known cluster-side peer failures (do not rebuild a node over these)

Operators across several providers hit a recurring pattern where nodes could not find peers at all, with log and metric signatures like:

```
discv5::service: No known_closest_peers found. Return empty result without sending query.
zksync_os_network::metrics: unknown counter metric key=KeyName("p2pstream.disconnected_errors")

network_backed_off_peers_too_many_peers 155
network_too_many_peers                  155
network_connected_peers                 0
network_pending_session_failures_outbound 155
```

This was diagnosed on ADI's side, not the operators', and was resolved by cluster-side fixes plus a node restart. So when you see this exact signature:

- Do **not** wipe the data directory, regenerate the secret key, or rebuild the stack.
- Confirm outbound TCP and UDP 3060 are permitted, then restart the node once.
- If it recurs, report it with the metric block above rather than re-installing. It is a known failure mode with a known signature, and the fix has historically been upstream.

This is the one place where escalating is the right call rather than continuing to diagnose locally.

## `state at block is pruned ...` at startup

**Cause:** the configured L1 RPC is a pruned endpoint. The node needs historical Ethereum state for genesis/upgrade discovery, and pruned endpoints answer recent blocks only.

**Action:** point `--l1-rpc-url` / `GENERAL_L1_RPC_URL` at an archive-capable L1 RPC and restart. This is a hard requirement, not a tuning knob.

Which L1 RPC: mainnet nodes need an archive Ethereum L1 endpoint (mainnet ENs read Ethereum mainnet), testnet nodes need an archive Sepolia endpoint. The operator usually already has one configured; ask before shopping for a new one, because free public endpoints mostly are not archive.

To test a candidate before restarting the node, ask it for state at an old block. A pruned endpoint errors, an archive one answers:

```bash
# Old block (100000) on a known address. Archive answers with a balance,
# pruned answers an error like "state at block #100000 is pruned".
curl -s -X POST "$L1_RPC" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_getBalance","params":["0x00000000219ab540356cBB839Cbe05303d7705Fa","0x186A0"],"id":1}'
```

Two traps seen in practice: an API key can be valid but out of quota (HTTP 429 monthly capacity exceeded), and a provider's free tier can serve recent state while refusing historical. Test the call the node actually makes, not just `eth_chainId`.

## Write errors / permission denied on the data directory

**Cause:** the host directory mounted at `/chain` is not writable by the container's unprivileged user. This is the most common first-start failure.

**Action:**

```bash
ls -ld ~/ADI-Stack-EN-Setup-script/mainnet_data
mkdir -p ~/ADI-Stack-EN-Setup-script/mainnet_data/db/node1
chmod 0777 ~/ADI-Stack-EN-Setup-script/mainnet_data ~/ADI-Stack-EN-Setup-script/mainnet_data/db ~/ADI-Stack-EN-Setup-script/mainnet_data/db/node1
```

Then start again. Do not delete the directory to clear the error.

## `Uncommitted changes` / git pull refuses

**Cause:** the setup checkout was edited locally (an old hand-tuned compose is the usual reason). Merging is deliberately not attempted: the upgrade path must be reproducible.

**Action:** inspect with `git -C ~/ADI-Stack-EN-Setup-script status`, decide whether the local edit is still needed (after v0.20.12 it usually is not: ports and variables moved into the new compose), then `git checkout -- <file>` or `git stash`. Never force-pull over an unknown edit.

## RPC up but transactions do not appear on the network

Transactions submitted to the external node go into its local mempool and are forwarded to the main node via `general_main_node_rpc_url`. If that value is unset or wrong, transactions stay local. Confirm the node is caught up first; forwarding a transaction from a lagging node is not meaningful.

## Node restarted and lost its P2P identity / is resyncing from scratch

**Cause:** `network_secret_key` / `EXTERNAL_NETWORK_SECRET_KEY` changed between starts. Losing it forces a full resync.

**Action:** find the original value before doing anything else, in this order:

1. The running container's config, which is the fastest and works even if the logs are gone: `docker inspect adi_mainnet_external_node --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -i secret`
2. An ops note or password manager entry for this node.
3. The first start's output, if it was captured (`EXTERNAL_NETWORK_SECRET_KEY not provided, generated automatically: <hex>`).
4. `adi-node`'s state file, `~/.adi-node/state.json`, if the CLI was ever used on this machine.

Restore the value and restart with it. Do not generate a new key while trying to recover an existing node's identity.

## "Node is running but eth_blockNumber fails"

Check which ports answer:

```bash
for p in 3050 3071 3312 3060; do (nc -z 127.0.0.1 $p && echo "$p open") || echo "$p closed"; done
```

- 3050 closed, 3071 open → the node process is up but JSON-RPC has not started serving. Normal in the first minutes; if it persists for hours without `Replay block` progress, see the stalled case above.
- Everything closed, container `Up` → look at the logs; the container may be crash-looping (`restart: unless-stopped` masks this in `docker ps`). Use `docker ps` status text (`Restarting (1) 5 seconds ago`) to spot it.

## Escalation

Escalate when the diagnosis points outside this machine, to whoever operates the node's ADI contact or the foundation's node-ops channel. Include:

- `scripts/en-status.sh` output
- the container image tag (`docker ps` shows it)
- the last 200 log lines
- which network (mainnet or testnet) and how long the node has been running

Escalate when:

- the main node and the external node disagree on height after the EN reports `eth_syncing: false`
- `verifier authorization failures` or `missing VerifyBatchResult` recur
- a coordinated upgrade is live (the main node has moved) and the published image does not start
- the node has been stuck at the same height for hours with a healthy L1 RPC, clean logs, and peers connected
