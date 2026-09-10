#!/usr/bin/env bash
# bootstrap-node.sh — one-time prerequisites on an inference node. Needs sudo ONCE
# (docker group + nvidia runtime). Everything else in this repo runs unprivileged.
#
#   ssh amigx@<node> 'bash -s' < scripts/bootstrap-node.sh
#
# Idempotent. After it runs, LOG OUT AND BACK IN so the docker group applies.
set -euo pipefail
me="$(id -un)"

echo "[1/5] docker group"
if id -nG "$me" | grep -qw docker; then
  echo "  $me already in docker group"
else
  sudo usermod -aG docker "$me"
  echo "  added $me to docker group (re-login required)"
fi

echo "[2/5] NVIDIA container runtime registered with docker"
if command -v nvidia-ctk >/dev/null 2>&1; then
  if ! sudo docker info 2>/dev/null | grep -qi "Runtimes:.*nvidia"; then
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker
    echo "  nvidia runtime registered; docker restarted"
  else
    echo "  nvidia runtime already registered"
  fi
else
  echo "  WARN: nvidia-ctk not found — install nvidia-container-toolkit first" >&2
fi

echo "[3/5] directories"
mkdir -p "$HOME/inference/logs" "$HOME/inference/plugins" "$HOME/models" \
         "$HOME/.cache/huggingface" "$HOME/.cache/vllm"

echo "[4/5] hf CLI (via uv, user-local, no root)"
export PATH="$HOME/.local/bin:$PATH"
command -v uv >/dev/null 2>&1 || curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null
command -v hf >/dev/null 2>&1 || uv tool install -q "huggingface_hub[cli]"
hf version || true

echo "[5/5] power mode (Jetson only, informational)"
if command -v nvpmodel >/dev/null 2>&1; then sudo nvpmodel -q 2>/dev/null | head -1 || true; fi

echo "bootstrap done on $(hostname). Re-login, then: docker ps"
