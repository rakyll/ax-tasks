# ax-tasks

Demos that compose several [AX](https://github.com/agent-substrate/ax) Tasks into an execution tree and steer them while they run.

- `tree.sh`: a minimal tree (lead, backend, backend-tests, docs). Steering a node reaches it and every task below it.
- `rollout.sh`: a staged production rollout. A canary, then gate-checks between stages, us-central, a fan-out to three regions, and a final validate that joins them. Fixing a bad release rolls forward to an earlier version, top-down from the canary. Every task has its own identity and policy: a Gateway installed as its actor's egress policy, plus sandbox CPU and memory limits.
- `web/`: a web view of either tree, with steering, per-task suspend and resume, and a live activity feed.

```sh
TREE_SCRIPT=rollout.sh AX_BIN=ax web/server.py   # then open http://localhost:8377
```

For ax-servers built before #587, set `AX_LEGACY_SCHEMA=1`. See the header of each script for usage and environment variables.

`web/axel.svg` is the AX logo, from the AX repository.
