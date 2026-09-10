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

The operator Mac's `~/.ssh/config` multiplexes connections (`ControlMaster auto`,
`ControlPersist 1800`). Sessions that reuse a master opened *before* the bootstrap keep the
old group list and still get "permission denied" on the docker socket. Close the master once:

```bash
# [mac]
ssh -O exit -i ~/.ssh/radlab amigx@thor; ssh -O exit -i ~/.ssh/radlab amigx@spark0
```

It adds `amigx` to the `docker` group, registers the NVIDIA runtime with docker
(`nvidia-ctk runtime configure --runtime=docker`), installs the compose v2 CLI plugin under
`~/.docker/cli-plugins` if the host's docker has none (thor's Ubuntu `docker.io` package),
creates the directories, and installs the `hf` CLI under `~/.local/bin` via `uv`. **Log out and back in** afterwards (`docker ps` must
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

## 6. nemo and Home Assistant

nemo also runs system **Ollama** on :11434. Home Assistant (`172.16.3.3`,
`homeassistant.krad.internal`) calls it a few times a day (~19:40) and, until 2026-09-10, kept
`gemma4:e4b` loaded with `keep_alive=-1` (~10.6 GB of 15.6 GB) — which left no room for the
`core` profile.

**Measured 2026-09-10 (Ollama 0.20.4, models loaded alone, `free` used/available):**

| Host | Model in Ollama | Loaded size | Speed | Host after load |
|---|---|---|---|---|
| nema (8 GB, router stopped) | `nemotron-3-nano:4b` | 5.3 GB | 8.1 tok/s | 559 MB available |
| nema | `qwen3.5:4b` | 6.3 GB | 4.6 tok/s | 89 MB available (swapping) |
| nema | `gemma4:e2b` | 7.8 GB | 8.5 tok/s | 230 MB available (swapping) |
| nemo (16 GB, `core` resident) | `qwen3:4b-instruct-2507-q4_K_M` | 3.6 GB | 16 tok/s | 3.6 GB available |
| nemo (`core` resident) | `qwen3:4b` (thinking variant) | 4.2 GB | 16 tok/s but 20 s/answer | 3.0 GB available |

So nema cannot host an Ollama model next to its llama.cpp router at all, and barely alone.
**The working arrangement is: HA stays on nemo's Ollama, using `qwen3:4b-instruct-2507-q4_K_M`
(pulled 2026-09-10), with nemo's `core` profile resident.** `gemma4:e4b` was unloaded; nemo `core` is up.

> Not `qwen3:4b`: on Ollama that tag is the *thinking* variant (262K ctx, no thinking toggle in
> its template). With `think:false` it returns its reasoning monologue as the answer; with
> `think:true` it answers correctly but takes ~20 s (986 chars of reasoning at 16 tok/s). The
> instruct tag answers in ~1 s warm / 5 s cold and coexists with core at 3.6 GB spare.

### Repoint HA (operator, HA web UI — no agent access to HA)

1. Settings → Devices & services → **Ollama** (the entry is titled with nemo's URL).
2. Open the conversation-agent sub-entry (⋮ → **Reconfigure**, or **Configure** on older
   versions). Set **Model** = `qwen3:4b-instruct-2507-q4_K_M` (the list comes from the server),
   **Keep alive** = `300` seconds instead of `-1` so the 3.6 GB is only held around HA's calls,
   context window 8192 is fine. Submit.
3. Verify from a shell on nemo:
   ```bash
   # [node] nemo
   journalctl -u ollama -f          # expect POST /api/chat from 172.16.3.3 on the next HA call
   curl -s localhost:11434/api/ps   # expect qwen3:4b, not gemma4:e4b
   ```
4. Optional clean-up on nemo: `ollama rm gemma4:e4b qwen3-vl:8b qwen3:4b` frees 18 GB of a 116 GB
   disk (21 GB free today). Keep them if you want the swap-back option.

Until step 2 is done, HA's calls still ask for `gemma4:e4b`; with `core` resident Ollama will
refuse the load (7 GB free < 10.6 GB needed) and HA's agent errors — no crash, but no answer.

### If you still want HA on nema

Only viable with nema's llama.cpp router **retired** (its cheap-router job moves to thor:8004
`Qwen3-8B`) and preferably the NemoClaw k3s container removed: then `nemotron-3-nano:4b` fits
at ~8 tok/s. In HA, ⋮ → Reconfigure on the Ollama entry to change the URL to
`http://172.16.10.165:11434` (or add a second Ollama integration with that URL and switch the
Assist pipeline / automation to the new agent), then `ACTION=down scripts/deploy.sh nema` and
`scripts/deploy.sh nema embeddings`.

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
| vLLM on Thor: `Free memory on device cuda:0 (20/122 GiB) … is less than desired GPU memory utilization` right after stopping another big model | on JetPack 7 (r38.4) the stopped container's GPU allocation can stay owned by the driver after a clean exit: `free` shows ~85 GB used with no process holding it (`nvidia-smi --query-compute-apps` lists only live PIDs). Observed 2026-09-10 after stopping the 10-day-old `vllm-qwen3-coder`. Only a reboot released it. Plan cutovers as: stop old → reboot → deploy |
| VLM returns 500 on an image | image must be ≥ 28×28 px (Qwen-VL patch size); tiny test pixels fail |
| Home Assistant conversation slow after nemo work | HA's gemma4 was unloaded; first call reloads it (~30 s) |
| name doesn't resolve | tailnet: `tailscale status`; lab: `dig @172.29.0.153 <name>.batfang.lab` |
| container start fails with `failed to create the automatic CDI … GPU requires reset` (DGX Spark) | the GB10 itself is in a reset-required state: `nvidia-smi -q \| grep -i reset` shows it, kernel log shows `NVRM … NV_ERR_GPU_IN_FULLCHIP_RESET`. Nothing docker-side fixes it: `sudo nvidia-smi -r` or `sudo reboot`, then redeploy. Seen 2026-09-10 after 10 days uptime |
