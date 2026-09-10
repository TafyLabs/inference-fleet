# Runbook

Everything here runs as `amigx` over Tailscale SSH with `~/.ssh/radlab`. Only the one-time
bootstrap on thor and spark0 needs sudo (docker group + NVIDIA runtime registration).

Command blocks are labelled **[mac]** (your laptop, anywhere on the tailnet) or **[node]**
(a shell on the device).

## 0. Names

| Node | Tailnet (MagicDNS) | Lab DNS (`batfang.lab`, served by nsd0/nsd1) | LAN IP (DHCP!) |
|---|---|---|---|
| nema | `nema`, `nema.tail1fae5.ts.net` | `nema`, `orin-nano`, `orin-super-nano` | 172.16.10.165 (eth) / .240 (wifi) |
| nemo | `nemo` | `nemo`, `orin-nx` | 172.16.1.223 |
| thor | `thor` | `thor`, `thor-agx` | 172.29.4.167 |
| spark0 | `spark0` | `spark0`, `dgx-spark` | 172.16.10.76 |

Use the tailnet names from laptops and agents on the tailnet; use `*.batfang.lab` from the
k3s cluster and anything whose resolver is the lab DNS pair. The Jetsons' own resolver is the
UniFi gateway (`172.16.0.1`, domain `krad.internal`), which does **not** forward `batfang.lab`.
The `.lab` bare TLD from the planning table does not exist; `batfang.lab` is the zone.
LAN addresses are DHCP leases — add static reservations on the UniFi gateway or expect to
re-edit `dns/batfang.lab.snippet` when a lease rolls (`nema` already moved once).

## 1. One-time node bootstrap (thor, spark0 — needs sudo once)

```bash
# [mac] — copies the script to the node, then runs it with a real terminal so sudo can prompt
ACTION=sync scripts/deploy.sh thor   && ssh -i ~/.ssh/radlab -t amigx@thor   bash inference/bootstrap-node.sh
ACTION=sync scripts/deploy.sh spark0 && ssh -i ~/.ssh/radlab -t amigx@spark0 bash inference/bootstrap-node.sh
```

Piping the script over stdin (`'bash -s' < …`) does not work: with stdin taken, `ssh -t`
cannot allocate a terminal and sudo has nowhere to read the password.

It adds `amigx` to the `docker` group, registers the NVIDIA runtime with docker
(`nvidia-ctk runtime configure --runtime=docker`), creates the directories, and installs the
`hf` CLI under `~/.local/bin` via `uv`. **Log out and back in** afterwards (`docker ps` must
work without sudo). nema and nemo already satisfy all of this.

## 2. Models

```bash
# [node]  (already done for all four nodes on 2026-09-10; re-run any time — it resumes/skips)
cd ~/inference && bash fetch-models.sh models-<node>.txt
```

The manifests are `nodes/<node>/models.txt`. Nothing in the plan is gated, so no HF token is
needed. GGUF files land in `~/models`; safetensors in `~/.cache/huggingface/hub`; vLLM parser
plugins (Nemotron Super) in `~/inference/plugins`.

## 3. Deploy

```bash
# [mac]
scripts/deploy.sh nema                # core: 9080 router + 9082 embeddings
scripts/deploy.sh nema core vlm       # + 9081 Qwen3-VL-2B
scripts/deploy.sh nemo core           # 8080 Qwen3-8B      (see §6 first)
scripts/deploy.sh thor robotics       # Profile D
scripts/deploy.sh thor robotics agent # D + E
scripts/deploy.sh spark0 agent        # Profile A
ACTION=down scripts/deploy.sh spark0  # stop everything on a node
ACTION=ps   scripts/deploy.sh thor
scripts/healthcheck.sh [node]         # /v1/models + a 16-token chat on each endpoint
```

`deploy.sh` rsyncs `nodes/<node>/` to `~/inference/<node>/` on the host and runs
`docker compose --profile … up -d`. Containers restart on reboot (`unless-stopped`).

## 4. thor cutover (the one manual step that touches a live consumer)

thor still runs the May bring-up: a `docker run` container `vllm-qwen3-coder` (Jetson AI Lab
vLLM 0.19 image) serving `Qwen3-Coder-Next` on **:8000**, which OpenFang consumes as
`vllm/Qwen3-Coder-Next` via `VLLM_HOST=http://thor.batfang.lab:8000/v1`
(batclaw-openfang `base/configmap.yaml`; three agents were PATCHed to that model name in #205).
A second container `vllm-qwen3.6-35B-A3B` has been crash-looping on the same port for weeks.

```bash
# [node] thor — after bootstrap + re-login
docker rm -f vllm-qwen3.6-35B-A3B          # the crash-looper; nothing depends on it
docker stop vllm-qwen3-coder               # frees :8000 and ~85 GB
cd ~/inference/thor
docker compose --profile robotics up -d    # 8004 → 8000 → 8002, serialized by healthchecks
docker compose --profile robotics ps       # wait for (healthy); first start compiles graphs
curl -s localhost:8000/v1/models
```

Then point OpenFang at the new names: `Qwen3.8-27B` on :8000 (replaces `Qwen3-Coder-Next`),
`Qwen3-8B` on :8004 for cheap routes. `audio_base_url` (faster-whisper) used :8001, which is
now Nemotron 3.5 — redeploy whisper on **:8100** when it comes back. If the new image turns out
not to run on Thor, `docker start vllm-qwen3-coder` restores the old service in under a minute;
the old model files are untouched in `~/.cache/huggingface`.

Start the small model first if you want a fast yes/no on the image:
`docker compose run --rm --service-ports qwen3-8b` and watch for `quantization=modelopt_fp4`.

## 5. spark0 first run

```bash
# [node] spark0 — after bootstrap + re-login, downloads finished (~185 GB)
cd ~/inference/spark0
docker compose --profile agent up -d       # Profile A
docker compose --profile agent logs -f qwen3_6-35b-a3b   # until "Application startup complete"
```

NVIDIA's OpenClaw / NemoClaw / Hermes DGX Spark playbooks expect exactly this endpoint:
`http://spark0:8000/v1`, model `Qwen3.6-35B-A3B`. Switch profiles with `ACTION=down` first;
`heavy` (Nemotron Super 120B, 0.88 of memory) must run alone.

## 6. nemo and Home Assistant (decision needed)

nemo also runs system **Ollama** on :11434. Home Assistant (`172.16.3.3`,
`homeassistant.krad.internal`) calls it a few times a day and keeps `gemma4:e4b` loaded
with `keep_alive=-1` (~10.6 GB of 15.6 GB). With that resident, the `core` profile (Qwen3-8B,
~6.5 GB) does not fit. The stack was validated on 2026-09-10 in a temporary window (the
model was unloaded via the API, `core`+`vlm` tested, then torn down; HA reloads its model on
its next call).

Options, cheapest first:
1. Point HA's Ollama agent at a smaller model on nemo (`ollama pull qwen3:4b` or move
   `gemma4:e2b` there) — frees ~6 GB; `core` fits.
2. Point HA at nema's Ollama (`nema:11434`, already has `gemma4:e2b`, `qwen3.5:4b`,
   `nemotron-3-nano:4b`) — nema then needs the `vlm` profile off (8 GB board).
3. Point HA at an OpenAI-compatible endpoint (nemo:8080 `qwen3-8b`) via HA's OpenAI-compatible
   conversation integration — then Ollama on nemo can be disabled entirely.
4. Leave HA as is and treat nemo as HA's box: run only `vlm` (3.5 GB) next to it.

Ollama's `keep_alive` is set by the caller (HA), so a server-side `OLLAMA_KEEP_ALIVE` will not
change this. Do not `systemctl disable ollama` on nemo until HA is repointed.

## 7. nema notes

- Port 8080 is held by the NemoClaw/OpenShell k3s container (`openshell-cluster-nemoclaw`,
  ~1 GB, up since June). That is why nema serves on 908x instead of 8080/8081. Retire it
  (`docker rm -f openshell-cluster-nemoclaw`) if NemoClaw-on-Nano is finished, and the ports
  can move to the table's 8080/8081.
- `~/nemo.sh` contains a plaintext Hugging Face token, world-readable. Rotate it at
  https://huggingface.co/settings/tokens and delete the file; nothing in this repo needs a token.
- Power mode is already `MAXN_SUPER`; nemo is `MAXN`.
- The old `gemma-2-2b-it` router is gone (`llama-cheap-router` / `llama-embeddings` docker-run
  containers were replaced by the compose stack; the embeddings server is byte-for-byte the
  same model and port). OpenFang's LM-Studio provider pointed at `nema:9080` with model id
  `gemma-2-2b-cheap-router`; the id is now `qwen3-4b-instruct-2507`.

## 8. Troubleshooting

| Symptom | Check |
|---|---|
| container `unhealthy`, restarts climbing | `docker logs <name>`; on 8/16 GB Orins it is usually memory — lower `--ctx-size`, stop a profile |
| vLLM stuck at start for 20+ min | normal on first run (torch.compile + CUDA graphs). `docker logs -f`; `~/.cache/vllm` caches it |
| vLLM OOM during KV profiling | lower that service's `--gpu-memory-utilization`; the fractions in a profile must sum ≲ 0.85 |
| `Unknown architecture` from vLLM | bump `VLLM_IMAGE` in `nodes/<node>/.env` (v0.29.0 is current); Qwen3.8 = `Qwen3_5ForConditionalGeneration`, present since v0.27.1 |
| MoE NVFP4 model slow / wrong on GB10 or Thor | `VLLM_USE_FLASHINFER_MOE_FP4=0` + `--moe-backend marlin` are set; don't remove them |
| Nemotron 3.5 fails on the DSpark draft | drop the `--speculative-config` line; it is an optimization only |
| VLM returns 500 on an image | image must be ≥ 28×28 px (Qwen-VL patch size); tiny test pixels fail |
| Home Assistant conversation slow after nemo work | HA's gemma4 was unloaded; first call reloads it (~30 s) |
| name doesn't resolve | tailnet: `tailscale status`; lab: `dig @172.29.0.153 <name>.batfang.lab` |
