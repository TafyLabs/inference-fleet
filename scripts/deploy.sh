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
rsync -az -e "ssh ${ssh_opts[*]}" "$here/scripts/bootstrap-node.sh" "$here/scripts/fetch-models.sh" "$SSH_USER@$node:inference/"

# Ordered start-up: nodes/<node>/profiles.txt maps "profile: svc svc …"; each service is started
# alone and must report healthy (or SERVICES="a b" overrides the list). Two vLLM instances must
# never profile free memory at the same moment on a unified-memory box.
order=()
if [[ -n "${SERVICES:-}" ]]; then
  order=($SERVICES)
elif [[ -f "$src/profiles.txt" ]]; then
  for p in "$@"; do
    for svc in $(grep -E "^$p:" "$src/profiles.txt" | cut -d: -f2-); do
      [[ " ${order[*]:-} " == *" $svc "* ]] || order+=("$svc")
    done
  done
fi
WAIT_STEPS="${WAIT_STEPS:-120}"   # x30s = max wait per service (first vLLM start can take 20-30 min)
ordered_up='set -e
docker compose PROFILES pull -q 2>&1 | tail -2 || true
for svc in ORDER; do
  echo "[up] $svc"
  docker compose PROFILES up -d --no-deps "$svc"
  cid=$(docker compose PROFILES ps -q "$svc")
  ok=0
  for i in $(seq 1 WAITSTEPS); do
    st=$(docker inspect --format "{{.State.Health.Status}}" "$cid" 2>/dev/null || echo missing)
    rc=$(docker inspect --format "{{.RestartCount}}" "$cid" 2>/dev/null || echo 0)
    if [[ "$st" == healthy ]]; then echo "  healthy after $((i*30))s"; ok=1; break; fi
    if [[ "$rc" -ge 2 || "$st" == unhealthy ]]; then
      echo "  FAILED ($svc restarts=$rc health=$st) — last log lines:"; docker logs --tail 40 "$cid" 2>&1 | cut -c1-220; exit 1
    fi
    sleep 30
  done
  [[ $ok -eq 1 ]] || { echo "  timeout waiting for $svc"; docker logs --tail 20 "$cid" 2>&1 | cut -c1-220; exit 1; }
done
docker compose PROFILES ps'
ordered_up="${ordered_up//PROFILES/${profiles[*]}}"
ordered_up="${ordered_up//ORDER/${order[*]:-}}"
ordered_up="${ordered_up//WAITSTEPS/$WAIT_STEPS}"

case "$ACTION" in
  up)   if [[ ${#order[@]} -gt 0 ]]; then remote="$ordered_up"; else remote="docker compose ${profiles[*]} up -d --remove-orphans && docker compose ${profiles[*]} ps"; fi ;;
  down) remote="docker compose --profile '*' down" ;;
  ps)   remote="docker compose --profile '*' ps" ;;
  pull) remote="docker compose ${profiles[*]} pull" ;;
  sync) echo "[sync] done"; exit 0 ;;
  *) echo "bad ACTION=$ACTION" >&2; exit 2 ;;
esac
echo "[$ACTION] profiles: ${*:-<none>}"
ssh "${ssh_opts[@]}" "$SSH_USER@$node" "cd ~/inference/$node && $remote"
