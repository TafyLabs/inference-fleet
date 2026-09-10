# Deployment profiles

Compose profiles are how you swap purposefully instead of running one giant menu.
`--gpu-memory-utilization` in vLLM is a fraction of the whole unified-memory pool **per
container**, so the numbers below must sum to well under 1.0 (leave ~15 % for the OS,
the CPU side of each process, and the Orins' desktop session).

## DGX Spark (`spark0`, 128 GB)

| Plan | Compose profile | Services (port) | Memory fraction |
|---|---|---|---|
| **A — default agent/dev** | `agent` | Qwen3.6-35B-A3B (8000) · Nemotron-3.5-Lightning (8001) · Qwen3-8B (8004) | 0.40 + 0.25 + 0.10 = **0.75** |
| **B — dev/coding** | `dev` | Qwen3.8-27B (8002) · Nemotron-3.5-Lightning (8001) · Qwen3-8B (8004) | 0.30 + 0.25 + 0.10 = **0.65** |
| **C — heavy reasoning** | `heavy` | Nemotron-3-Super-120B (8005) alone | **0.88** |
| multimodal add-on | `multimodal` | Nemotron-3-Nano-Omni (8003) | 0.25 — run it *instead of* 8001 or 8002 |

```bash
scripts/deploy.sh spark0 agent          # A
scripts/deploy.sh spark0 dev            # B (stops nothing by itself — run ACTION=down first to switch)
ACTION=down scripts/deploy.sh spark0 && scripts/deploy.sh spark0 heavy   # C
```

Profile A is what NVIDIA's OpenClaw / Hermes DGX Spark playbooks point at
(`http://spark0:8000/v1`, model `Qwen3.6-35B-A3B`).

## Jetson AGX Thor (`thor`, 128 GB)

| Plan | Compose profile | Services (port) | Memory fraction |
|---|---|---|---|
| **D — robotics edge** | `robotics` | Qwen3.8-27B (8000) · Qwen3-VL-8B (8002) · Qwen3-8B (8004) | 0.30 + 0.10 + 0.10 = **0.50** |
| **E — long-running agent** | `agent` | Nemotron-3.5-Lightning (8001) · Qwen3-8B (8004) | 0.25 + 0.10 = **0.35** |
| D + E together | `robotics agent` | all of the above | **0.75** |
| multimodal add-on | `multimodal` | Nemotron-3-Nano-Omni (8003) | 0.25 — only with D *or* E, not both |

## Orin NX (`nemo`, 16 GB) and Orin Nano Super (`nema`, 8 GB)

| Node | Profile | Services | Approx. resident RAM |
|---|---|---|---|
| nemo | `core` | Qwen3-8B Q4_K_M (8080) | ~6.5 GB |
| nemo | `quality` | Qwen3-14B Q4_K_M (8081), ctx 8k | ~10 GB — swap-in, stop `core` first if Ollama is loaded |
| nemo | `vlm` | Qwen3-VL-4B GGUF (8000) | ~3.5 GB |
| nema | `core` | Qwen3-4B (9080) + nomic embeddings (9082) | ~3.5 GB |
| nema | `vlm` | Qwen3-VL-2B (9081) | +~2.5 GB — swap-in |

nemo also hosts system Ollama (`:11434`), which Home Assistant keeps pinned to
`gemma4:e4b` (~10.6 GB). Until that changes, only `vlm` alone or nothing fits next to it.
See `docs/runbook.md` → "nemo and Home Assistant".

## Startup order

vLLM sizes its KV cache from *free* memory at start-up. Each compose file chains
`depends_on … service_healthy` so the router (8004) comes up first, then the main model,
then sidecars; two large models never profile memory at the same moment. First start of a
model on a node compiles kernels and captures CUDA graphs (10–20 min on Thor / Spark);
`~/.cache/vllm` persists them so later starts take a minute or two. Healthchecks allow 30 min.
