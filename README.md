# ADI External Node agent skill

An [Agent Skill](https://agentskills.io/specification) that lets any coding agent safely operate and monitor an ADI Chain external node: start, stop, upgrade between EN versions, and diagnose the usual sync/health problems.

Drop-in for engineers who run an external node on a VM or VPS with Docker and the [ADI-Stack-EN-Setup-script](https://github.com/ADI-Foundation-Labs/ADI-Stack-EN-Setup-script) checkout. No build step, no extra tooling, no knowledge of ADI internals required from the agent.

## Install

```bash
# into the current project (writes .agents/skills/<name>/, symlinks other harnesses)
npx skills add idea404/adi-external-node-skill

# globally, for every project on this machine
npx skills add idea404/adi-external-node-skill -g

# pick a specific harness non-interactively
npx skills add idea404/adi-external-node-skill -g -a claude-code -y
```

Works with any harness that reads `SKILL.md` (Claude Code, Codex, OpenCode, Cursor, Amp, and the rest of the `skills` CLI's supported agents). Harnesses without skill support can simply be pointed at `skills/adi-external-node/SKILL.md`.

## Use

Ask the agent to check or upgrade the node, or invoke the skill directly in harnesses that support slash commands of this kind:

```
/skill:adi-external-node check the external node on this box and tell me if it needs anything
```

The skill carries one script, `scripts/en-status.sh`, a read-only health snapshot. It needs only `bash`, `curl`, and `docker`, prints containers, head block, lag against the network reference RPC, block rate, P2P peers, pipeline lag, and disk usage, and ends in a single verdict line:

| Verdict | Exit | Meaning |
|---|---|---|
| `HEALTHY` | 0 | caught up |
| `SYNCING` | 0 | behind, head advancing (normal) |
| `STALLED` | 1 | behind, head not advancing |
| `DEGRADED` | 1 | up, but no peers or RPC not answering yet |
| `UNKNOWN` | 1 | node up, reference RPC unreachable |
| `DOWN` | 2 | no container on this machine, no RPC |
| `STOPPED` | 2 | container exists but is not running |

```bash
bash skills/adi-external-node/scripts/en-status.sh
# exit code doubles as a monitoring signal
```

## Layout

```
skills/adi-external-node/
├── SKILL.md                      # the skill: rules, health check, upgrade shape
├── scripts/en-status.sh          # read-only health snapshot with a verdict
└── references/
    ├── network.md                # networks, ports, versions, upgrade checklist
    └── troubleshooting.md        # symptom → cause → action
```

## Safety properties

The skill is written for an agent acting on someone's production node, so it encodes hard rules rather than relying on the model's judgement:

- never delete the chain data directory or regenerate the P2P secret key (either forces a full resync from genesis)
- upgrades are treated as coordinated, network-wide events, gated on the upgrade actually being live for the network
- diagnosis comes before change, via a script that cannot mutate anything
- rollback is a documented path (revert the setup repo, restart with the same key), not an improvised one

## Updating

`skills update` works from the git history: bump the version in `SKILL.md` frontmatter alongside content changes so installed copies can tell them apart.

## Verification

Validated against the Agent Skills spec:

```bash
npx skills-ref validate skills/adi-external-node
npx skills add ./ --list
```

`en-status.sh` was exercised against the live mainnet reference RPC and against a fake node in each state (syncing, caught up, stalled, no peers) to confirm every verdict and exit code.

It was then run against a real testnet node (v0.20.12-b1, replaying from genesis on an Ubuntu box) and driven by a separate agent session: the agent read the skill, ran the script, reported `SYNCING` as normal rather than a fault, and declined to restart the node to "clear" the alarm. Two bugs came out of that run and are fixed: the connected-peer metric name, and a stopped container being reported as no container at all.

## License

MIT. See [LICENSE](LICENSE).
