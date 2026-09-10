#!/usr/bin/env bash
# deploy.sh — sync one node's stack to the host and (re)start the selected profiles.
#
#   scripts/deploy.sh <node> [compose profile ...]
#   scripts/deploy.sh nema                 # default profile for that node
#   scripts/deploy.sh thor robotics        # Profile D
#   scripts/deploy.sh spark0 agent         # Profile A
#   ACTION=down scripts/deploy.sh thor     # stop everything on thor
#
# Env: SSH_KEY (default ~/.ssh/radlab), SSH_USER (default amigx), ACTION (up|down|ps|pull|sync)
#   ACTION=sync only rsyncs the node dir (use before the node has docker access).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
node="${1:?node name (nema|nemo|thor|spark0)}"; shift || true
SSH_KEY="${SSH_KEY:-$HOME/.ssh/radlab}"; SSH_USER="${SSH_USER:-amigx}"; ACTION="${ACTION:-up}"
src="$here/nodes/$node"; [[ -d "$src" ]] || { echo "no such node dir: $src" >&2; exit 2; }

# default profile per node when none given
if [[ $# -eq 0 ]]; then
  case "$node" in
    nema)   set -- core ;;
    nemo)   set -- core ;;
    thor)   set -- robotics ;;
    spark0) set -- agent ;;
  esac
fi
profiles=(); for p in "$@"; do profiles+=(--profile "$p"); done

ssh_opts=(-i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
echo "[sync] $src -> $SSH_USER@$node:~/inference/$node/"
rsync -az --delete --exclude 'logs/' -e "ssh ${ssh_opts[*]}" "$src/" "$SSH_USER@$node:inference/$node/"

case "$ACTION" in
  up)   remote="docker compose ${profiles[*]} up -d --remove-orphans && docker compose ${profiles[*]} ps" ;;
  down) remote="docker compose --profile '*' down" ;;
  ps)   remote="docker compose --profile '*' ps" ;;
  pull) remote="docker compose ${profiles[*]} pull" ;;
  sync) echo "[sync] done"; exit 0 ;;
  *) echo "bad ACTION=$ACTION" >&2; exit 2 ;;
esac
echo "[$ACTION] profiles: ${*:-<none>}"
ssh "${ssh_opts[@]}" "$SSH_USER@$node" "cd ~/inference/$node && $remote"
