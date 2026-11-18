# ax-tasks

Demos that compose several [AX](https://github.com/agent-substrate/ax) Tasks and steer them while they run.

- `tree.sh`: a minimal tree (lead, backend, backend-tests, docs). Steering a node reaches it and every task below it.
- `rollout.sh`: a staged production rollout. A canary, then gate-checks between stages, us-central, a fan-out to three regions, and a final validate that joins them. Fixing a bad release rolls forward to an earlier version, top-down from the canary. Every task has its own identity and policy: a Gateway installed as its actor's egress policy, plus sandbox CPU and memory limits.
- `collab.sh`: Antigravity and Claude Code fix a bug and test it together. Both agents' Tasks start from the same AX Workspace (a small checkout service with a bug, its issue and the team's conventions). Each Task gets its own copy, so they collaborate in commits: antigravity fixes, claude-code writes the tests and reviews, and patches go back and forth until every test passes. Each agent's gateway lets it reach only its own model API.
- `web/`: a web view with one tab per demo, with steering, per-task suspend and resume, and a live activity feed.

```sh
TREE_SCRIPTS=rollout.sh,collab.sh AX_BIN=ax web/server.py   # then open http://localhost:8377
```

For ax-servers built before #587, set `AX_LEGACY_SCHEMA=1`. See the header of each script for usage and environment variables.

`web/axel.svg` is the AX logo, from the AX repository.
