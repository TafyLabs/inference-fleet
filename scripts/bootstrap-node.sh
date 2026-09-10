#!/usr/bin/env bash
# bootstrap-node.sh — one-time prerequisites on an inference node. Needs sudo ONCE
# (docker group + nvidia runtime). Everything else in this repo runs unprivileged.
#
#   scp scripts/bootstrap-node.sh amigx@<node>:inference/   # deploy.sh does this for you
#   ssh -t amigx@<node> bash inference/bootstrap-node.sh      # -t so sudo can prompt
#
# (Do NOT pipe the script over stdin with 'bash -s' — sudo then has no terminal to read
# the password from.) Idempotent. After it runs, LOG OUT AND BACK IN so the docker
# group applies.
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

echo "[2b/5] docker compose v2 plugin (user-local; Ubuntu's docker.io package ships none)"
if docker compose version >/dev/null 2>&1 || sudo docker compose version >/dev/null 2>&1; then
  echo "  compose present"
else
  tag=$(curl -fsSL https://api.github.com/repos/docker/compose/releases/latest | python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"])')
  arch=$(uname -m); [[ "$arch" == "arm64" ]] && arch=aarch64
  mkdir -p "$HOME/.docker/cli-plugins"; cd "$HOME/.docker/cli-plugins"
  curl -fsSL -o docker-compose "https://github.com/docker/compose/releases/download/$tag/docker-compose-linux-$arch"
  curl -fsSL -o docker-compose.sha256 "https://github.com/docker/compose/releases/download/$tag/docker-compose-linux-$arch.sha256"
  sed "s#\*\?docker-compose-linux-$arch#docker-compose#" docker-compose.sha256 | sha256sum -c - && rm docker-compose.sha256
  chmod +x docker-compose; cd - >/dev/null
  echo "  installed compose $tag to ~/.docker/cli-plugins"
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
