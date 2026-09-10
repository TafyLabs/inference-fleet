# inference-fleet

Local LLM / VLM serving for the Tafy Labs / RobotDen lab: three NVIDIA Jetsons and a DGX Spark,
all on the Tailscale network, each exposing OpenAI-compatible endpoints.

**Runtime rule:** `llama.cpp` for Orin text and small GGUF VLMs · `vLLM` for Thor / DGX Spark agent
work · TensorRT Edge-LLM only when turning a model into a productionized embedded appliance.

## Fleet

| Node | Hardware | Tailnet name | Lab DNS (`*.batfang.lab`) | Runtime | Image |
|---|---|---|---|---|---|
| `nema` | Jetson Orin Nano Super 8 GB · JetPack 6.2.2 | `nema` | `nema`, `orin-nano`, `orin-super-nano` | llama.cpp | `ghcr.io/nvidia-ai-iot/llama_cpp:b8708-r36.4-tegra-aarch64-cu126-22.04` |
| `nemo` | Jetson Orin NX 16 GB · JetPack 6.2.2 | `nemo` | `nemo`, `orin-nx` | llama.cpp (+ vLLM 0.19 alt) | same as nema |
| `thor` | Jetson AGX Thor 128 GB · JetPack 7 / CUDA 13 | `thor` | `thor`, `thor-agx` | vLLM | `vllm/vllm-openai:v0.27.1` (arm64) |
| `spark0` | DGX Spark GB10 128 GB · DGX OS 7.5 / CUDA 13 | `spark0` | `spark0`, `dgx-spark` | vLLM | `vllm/vllm-openai:v0.27.1` (arm64) |

Login user on every node is `amigx`. All endpoints are `http://<name>:<port>/v1`.

## Endpoints (source of truth: [`endpoints.txt`](endpoints.txt))

| Node | Port | Served model name | Checkpoint | Role | Load | Profile |
|---|---|---|---|---|---|---|
| nema | 9080 | `qwen3-4b-instruct-2507` | `unsloth/Qwen3-4B-Instruct-2507-GGUF` Q4_K_M | text router, cheap generation | resident | `core` |
| nema | 9081 | `qwen3-vl-2b-instruct` | `Qwen/Qwen3-VL-2B-Instruct-GGUF` Q4_K_M + mmproj F16 | snapshot VLM / OCR | swap-in | `vlm` |
| nema | 9082 | `nomic-embed-text-v1.5` | nomic Q8_0 | embeddings | resident | `core` |
| nemo | 8080 | `qwen3-8b` | `Qwen/Qwen3-8B-GGUF` Q4_K_M | daily-driver text | resident | `core` |
| nemo | 8081 | `qwen3-14b` | `Qwen/Qwen3-14B-GGUF` Q4_K_M | quality swap-in | swap-in | `quality` |
| nemo | 8000 | `qwen3-vl-4b-instruct` | `Qwen/Qwen3-VL-4B-Instruct-GGUF` Q4_K_M (alt: `cpatonn/…-AWQ-4bit` on vLLM) | medium VLM | swap-in | `vlm` / `vlm-vllm` |
| thor | 8000 | `Qwen3.8-27B` | `nvidia/Qwen3.8-27B-NVFP4` | robotics planner, coder, visual agent | resident | `robotics` |
| thor | 8001 | `Nemotron-3.5-Lightning-30B-A3B` | `nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4` (+DSpark draft) | long-running agent MoE | resident | `agent` |
| thor | 8002 | `Qwen3-VL-8B-Instruct` | `cpatonn/Qwen3-VL-8B-Instruct-AWQ-4bit` | fast VLM sidecar | resident | `robotics` |
| thor | 8003 | `Nemotron-3-Nano-Omni-30B-A3B` | `nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning-NVFP4` | audio/video/doc sidecar | swap-in | `multimodal` |
| thor | 8004 | `Qwen3-8B` | `nvidia/Qwen3-8B-NVFP4` | router, validator, retry fixer | resident | `robotics`,`agent` |
| spark0 | 8000 | `Qwen3.6-35B-A3B` | `nvidia/Qwen3.6-35B-A3B-NVFP4` | OpenClaw / NemoClaw / Hermes default | resident | `agent` |
| spark0 | 8001 | `Nemotron-3.5-Lightning-30B-A3B` | as thor | fast agent engine | resident | `agent`,`dev` |
| spark0 | 8002 | `Qwen3.8-27B` | as thor | dev / coding | swap-in | `dev` |
| spark0 | 8003 | `Nemotron-3-Nano-Omni-30B-A3B` | as thor | multimodal sidecar | swap-in | `multimodal` |
| spark0 | 8004 | `Qwen3-8B` | as thor | router, validator | resident | `agent`,`dev` |
| spark0 | 8005 | `Nemotron-3-Super-120B-A12B` | `nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4` (+MTPv2 draft) | heavy reasoning, runs alone | swap-in | `heavy` |

Profiles A–E from the plan map to compose profiles — see [`docs/profiles.md`](docs/profiles.md).

## Quick start

```bash
# from a machine on the tailnet with ~/.ssh/radlab
scripts/deploy.sh nema            # core profile (router + embeddings)
scripts/deploy.sh nema core vlm   # add the snapshot VLM
scripts/deploy.sh thor robotics   # Profile D (after one-time bootstrap, see runbook)
scripts/deploy.sh spark0 agent    # Profile A
ACTION=down scripts/deploy.sh spark0
scripts/healthcheck.sh            # /v1/models + a chat completion on every endpoint
```

Models are fetched once per node with `scripts/fetch-models.sh nodes/<node>/models.txt`
(unprivileged; uses the `hf` CLI installed via `uv`). Checkpoints live in `~/models` (GGUF)
and `~/.cache/huggingface` (safetensors); compiled vLLM graphs persist in `~/.cache/vllm`.

## Layout

```
endpoints.txt        registry consumed by healthcheck.sh — host, port, served name, role, profile
nodes/<node>/        compose.yaml + .env (pinned images, paths) + models.txt (manifest)
scripts/             bootstrap-node.sh · fetch-models.sh · deploy.sh · healthcheck.sh
docs/                runbook.md (bring-up, cutover, troubleshooting) · profiles.md · decisions.md
dns/                 batfang.lab records for the fleet
```

## Status (2026-09-10, end of day)

| Node | Live | Notes |
|---|---|---|
| `nema` | `core` (9080 Qwen3-4B router, 9082 embeddings) | VLM validated as a swap-in only (router must stop first on 8 GB) |
| `nemo` | nothing | stack validated end to end, then taken down: Home Assistant pins `gemma4:e4b` in the host's Ollama. Decision pending, runbook §6 |
| `thor` | `robotics` + `agent` (8000 Qwen3.8-27B, 8001 Nemotron 3.5, 8002 Qwen3-VL-8B, 8004 Qwen3-8B) | upstream vLLM v0.27.1 proven on JetPack 7. Legacy `Qwen3-Coder-Next` container stopped (kept for rollback). 8 GB headroom with D+E both resident — run one profile if anything else needs memory |
| `spark0` | `agent` = Profile A (8000 Qwen3.6-35B, 8001 Nemotron 3.5, 8004 Qwen3-8B) | Qwen3.6 at ~90 tok/s. 13 GB headroom |

Lessons that cost a reboot each: a long-running vLLM on Thor left ~83 GB driver-held after a clean stop, and the Spark's GB10 had been wedged since an Xorg-triggered Xid 120 — both in the runbook's troubleshooting table.

Vault context: `wiki/entities/local-inference-fleet.md` in the RobotDen vault.
