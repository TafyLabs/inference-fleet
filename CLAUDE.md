# inference-fleet — agent context

Local model serving for the Tafy Labs / RobotDen lab. Four nodes on the tailnet, all user
`amigx`, SSH key `~/.ssh/radlab`: `nema` (Orin Nano Super 8 GB), `nemo` (Orin NX 16 GB),
`thor` (AGX Thor 128 GB), `spark0` (DGX Spark 128 GB).

- Source of truth for endpoints: `endpoints.txt`. Per-node stacks: `nodes/<node>/compose.yaml`.
- Runtime rule: llama.cpp on the Orins, vLLM (upstream arm64, CUDA 13) on Thor and Spark.
- `scripts/deploy.sh <node> [profiles]` is the only way stacks are changed. Never hand-edit
  compose files on a node; edit here and redeploy.
- Read `docs/decisions.md` before "fixing" a deviation from the planning table — it is
  probably deliberate. `docs/runbook.md` has the sudo bootstrap, the thor cutover, and the
  Home Assistant constraint on nemo.
- Never commit tokens. Nothing here needs one (all checkpoints are public).
- Vault pages: `wiki/entities/local-inference-fleet.md` in the RobotDen vault.
