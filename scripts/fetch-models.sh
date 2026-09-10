#!/usr/bin/env bash
# fetch-models.sh — download the checkpoints listed in a manifest into this host's
# model store. Runs unprivileged. Idempotent (hf resumes / skips complete files).
#
# Manifest format (one entry per line, '#' comments allowed):
#   gguf <hf-repo> <filename>            -> $MODELS_DIR/<filename>      (llama.cpp)
#   hf   <hf-repo>                        -> $HF_HOME/hub/models--...    (vLLM)
#   plugin <hf-repo> <filename>          -> ~/inference/plugins/<filename> (vLLM parser plugins)
#
# Env: MODELS_DIR (default ~/models), HF_HOME (default ~/.cache/huggingface)
set -euo pipefail
MANIFEST="${1:?usage: fetch-models.sh <manifest>}"
MODELS_DIR="${MODELS_DIR:-$HOME/models}"
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"
export HF_HUB_ENABLE_HF_TRANSFER=0
export PATH="$HOME/.local/bin:$PATH"

if ! command -v hf >/dev/null 2>&1; then
  if ! command -v uv >/dev/null 2>&1; then
    curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null
  fi
  uv tool install -q "huggingface_hub[cli]" >/dev/null
fi
mkdir -p "$MODELS_DIR" "$HF_HOME"

fail=0
while read -r kind repo file _; do
  [[ -z "${kind:-}" || "$kind" == \#* ]] && continue
  case "$kind" in
    gguf)
      if [[ -s "$MODELS_DIR/$file" ]]; then echo "[skip] $file present"; continue; fi
      echo "[gguf] $repo :: $file -> $MODELS_DIR"
      hf download "$repo" "$file" --local-dir "$MODELS_DIR" --max-workers 8 || { echo "[FAIL] $repo/$file"; fail=1; }
      ;;
    hf)
      echo "[hf]   $repo -> $HF_HOME/hub"
      hf download "$repo" --max-workers 8 || { echo "[FAIL] $repo"; fail=1; }
      ;;
    plugin)
      mkdir -p "$HOME/inference/plugins"
      echo "[plug] $repo :: $file -> ~/inference/plugins"
      hf download "$repo" "$file" --local-dir "$HOME/inference/plugins" || { echo "[FAIL] $repo/$file"; fail=1; }
      ;;
    *) echo "[??] unknown kind '$kind' in manifest"; fail=1 ;;
  esac
done < "$MANIFEST"
echo "[done] exit=$fail $(date -Is)"
exit $fail
