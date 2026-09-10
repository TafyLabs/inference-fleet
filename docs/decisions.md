# Decisions and deviations from the planning table

The planning table (2026-09-10, in the RobotDen vault as
`raw/articles/Lab/LocalLLMRuntimeLoadout-2026-09-10.md`) is the source of truth for
*which model does which job on which device*. This file records where the deployed fleet
deliberately differs, and why.

| # | Table says | Deployed | Why |
|---|---|---|---|
| 1 | endpoints `orin-super-nano.lab`, `orin-nx.lab`, `thor-agx.lab`, `dgx-spark.lab` | canonical hostnames `nema`/`nemo`/`thor`/`spark0` on the tailnet; `*.batfang.lab` A records plus CNAME aliases `orin-nano`, `orin-super-nano`, `orin-nx`, `thor-agx`, `dgx-spark` | there is no `.lab` zone; the lab's authoritative zone is `batfang.lab`; the hosts already had these names, DNS records and consumers |
| 2 | nema ports 8080 (LLM) / 8081 (VLM) | 9080 / 9081 / 9082 | 8080 is held by the NemoClaw k3s container on nema; 908x is what the May bring-up and OpenFang already use |
| 3 | nemo VLM = `Qwen3-VL-4B-Instruct-AWQ` on vLLM | default `vlm` profile = official `Qwen/Qwen3-VL-4B-Instruct-GGUF` Q4_K_M on llama.cpp; `vlm-vllm` profile keeps the AWQ/vLLM path (`cpatonn/…-AWQ-4bit`, community quant — Qwen ships no official AWQ) | 116 GB NVMe with 23 GB free after models; the Orin vLLM image is another ~20 GB on disk for one 4B model; the runtime rule already says "llama.cpp for small GGUF VLMs" |
| 4 | Thor runtime = "vLLM container" | upstream `vllm/vllm-openai:v0.27.1` (arm64, CUDA 13), **not** the Jetson AI Lab image | the Jetson AI Lab Thor image is vLLM 0.19; Nemotron 3.5 Lightning and Nemotron Omni need ≥ 0.20/0.27; Jetson AI Lab's own JetPack-7 tutorials now run upstream vLLM on Thor. Unverified on this Thor until docker access exists — fallback image kept in `.env` |
| 5 | Thor 8001 = Nemotron 3.5 Lightning | same | but batclaw-openfang's `audio_base_url` reserved 8001 for faster-whisper (not currently running). Whisper moves to 8100 |
| 6 | Omni id `NVIDIA-Nemotron-3-Nano-Omni-30B-A3B-Reasoning-NVFP4` | `nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning-NVFP4` | that is the repo's actual name (no `NVIDIA-` prefix) |
| 7 | Qwen3-VL-8B "AWQ" | `cpatonn/Qwen3-VL-8B-Instruct-AWQ-4bit` | Qwen publishes FP8, not AWQ, for Qwen3-VL; this is the community W4A16 |
| 8 | nemo Qwen3-8B "resident" | validated but **not left running** | Home Assistant pins `gemma4:e4b` in nemo's Ollama (10.6 GB); both cannot be resident. Operator decision — runbook §6 |
| 9 | DGX Spark Qwen3-8B "NVFP4/W4A16" | `nvidia/Qwen3-8B-NVFP4` | official NVIDIA NVFP4 checkpoint exists (Sept 2025) |
| 10 | vLLM flags | per-model flags copied from NVIDIA's DGX Spark recipes on each model card (marlin MoE backend, fp8 KV, flashinfer attention, MTP/DSpark speculation, `qwen3_xml`/`qwen3_coder`/`nemotron_v3` parsers) | those are the tested configurations for GB10; Thor gets the same set pending validation |

## Memory arithmetic that shaped the profiles

- vLLM's `--gpu-memory-utilization` is a share of the whole 128 GB unified pool per container.
  Profiles were sized so the sum stays ≤ 0.75 with headroom for the OS: Spark A = 0.75, B = 0.65,
  C = 0.88 alone; Thor D = 0.50, E = 0.35, D+E = 0.75. Omni (0.25) is a swap-in, never an add-on
  to a full profile.
- Orin Nano (7.6 GB): Qwen3-4B (2.5 GB file) + embeddings + NemoClaw k3s ≈ 5.5 GB resident;
  the 2B VLM fits as a swap-in only.
- Orin NX (15.6 GB): Qwen3-8B (5 GB file, ~6.5 GB with 16k ctx) + VL-4B GGUF (3.5 GB) measured at
  13.4 GB used with both up. The 14B (9 GB) is a quality swap-in that replaces the 8B.

## Verified on 2026-09-10

- thor `robotics`+`agent` on upstream vLLM v0.27.1 (arm64, CUDA 13, JetPack 7 r38.4): Qwen3-8B-NVFP4 healthy in 3 min; Qwen3.8-27B-NVFP4 in 11.5 min first start (tool call OK, image → "RED"); Qwen3-VL-8B AWQ in 7 min (image → "Red"); Nemotron 3.5 Lightning NVFP4 + DSpark draft in 6.5 min (tool call OK, reasoning split). GPU memory held per process: 8B 12.9 GB, 27B 29.1 GB, VL-8B 17.6 GB, Nemotron 28.5 GB. **Open question 1 and 2 below are answered: yes and yes.**
- spark0 `agent` (Profile A): Qwen3-8B 3 min, Qwen3.6-35B-A3B-NVFP4 5 min (tool call OK, 200 tokens at 90.6 tok/s), Nemotron 3.5 + DSpark 5 min (tool call OK, reasoning split). 108 GB used / 13 GB free with all three resident.

- nema `core`: `/v1/models`, chat (28.9 tok/s), OpenAI tool call, `/v1/embeddings` (768-d, unit norm).
- nemo `core`+`vlm`: chat (14.7 tok/s), thinking split into `reasoning_content`, tool call.
- DNS: `spark0` A record + five CNAMEs live on nsd0 and nsd1, serial 2026091001.
- Every checkpoint in the table exists on Hugging Face, none gated; sizes recorded in `nodes/*/models.txt` commits.

## Open questions

1. ~~Does upstream vLLM v0.27.1 arm64 run on Thor's sm_110 with these NVFP4 checkpoints?~~ Yes (2026-09-10).
2. ~~Nemotron 3.5 DSpark speculative decoding on Thor.~~ Starts and serves; throughput not yet measured against no-draft.
3. NemoClaw on nema — still wanted? It costs 8080 and ~1 GB on an 8 GB board.
4. Home Assistant's conversation agent — which of the four options in runbook §6.
5. Static DHCP reservations for the four LAN addresses (UniFi) so the zone stops drifting.
6. TensorRT Edge-LLM / GR00T VLA track on Thor — separate policy-model endpoint, not in this repo yet.
7. OpenFang still points at `Qwen3-Coder-Next` on thor:8000 (now `Qwen3.8-27B`) and at `gemma-2-2b-cheap-router` on nema:9080 (now `qwen3-4b-instruct-2507`) — repoint in batclaw-openfang.
8. Thor with D+E both resident has ~8 GB headroom; VL-8B uses 17.6 GB against a 0.10 (12 GB) budget because the vision encoder and CUDA graphs sit outside vLLM's KV accounting. Consider `--gpu-memory-utilization 0.08` for the VL sidecar or running D or E alone.
