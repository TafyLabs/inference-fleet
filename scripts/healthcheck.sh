#!/usr/bin/env bash
# healthcheck.sh — smoke-test every endpoint listed in endpoints.txt (or one host).
# Works from anywhere that can reach the nodes (tailnet MagicDNS names by default).
#
#   scripts/healthcheck.sh            # all endpoints
#   scripts/healthcheck.sh thor       # only thor's rows
#   DOMAIN=.batfang.lab scripts/healthcheck.sh   # use lab DNS names instead of MagicDNS
#
# For each row: GET /v1/models, then a 16-token chat completion. Prints latency.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
only="${1:-}"; DOMAIN="${DOMAIN:-}"
pass=0; fail=0; skip=0
while read -r host port model role load _; do
  [[ -z "${host:-}" || "$host" == \#* ]] && continue
  [[ -n "$only" && "$host" != "$only" ]] && continue
  base="http://${host}${DOMAIN}:${port}/v1"
  if ! models=$(curl -fsS -m 6 "$base/models" 2>/dev/null); then
    if [[ "${load:-}" == "swap-in" ]]; then
      printf "%-7s :%-5s %-44s off    (%s, swap-in)\n" "$host" "$port" "$model" "$role"; ((skip++))
    else
      printf "%-7s :%-5s %-44s DOWN   (%s)\n" "$host" "$port" "$model" "$role"; ((fail++))
    fi
    continue
  fi
  served=$(printf '%s' "$models" | python3 -c 'import sys,json; print(",".join(m["id"] for m in json.load(sys.stdin)["data"]))' 2>/dev/null)
  t0=$(date +%s.%N)
  if [[ "$role" == "embeddings" ]]; then
    if dims=$(curl -fsS -m 30 "$base/embeddings" -H 'Content-Type: application/json' -d "{\"model\":\"$model\",\"input\":\"ping\"}" 2>/dev/null | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["data"][0]["embedding"]))' 2>/dev/null); then
      printf "%-7s :%-5s %-44s OK   dims=%s  serves=[%s]\n" "$host" "$port" "$model" "$dims" "$served"; ((pass++))
    else
      printf "%-7s :%-5s %-44s UP-but-embeddings-FAILED\n" "$host" "$port" "$model"; ((fail++))
    fi
    continue
  fi
  if out=$(curl -fsS -m 120 "$base/chat/completions" -H 'Content-Type: application/json' \
      -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word: pong\"}],\"max_tokens\":16,\"temperature\":0,\"chat_template_kwargs\":{\"enable_thinking\":false}}" 2>/dev/null); then
    dt=$(python3 -c "print(f'{$(date +%s.%N)-$t0:.1f}s')")
    txt=$(printf '%s' "$out" | python3 -c 'import sys,json; d=json.load(sys.stdin); print((d["choices"][0]["message"].get("content") or "").strip().replace("\n"," ")[:40])' 2>/dev/null)
    printf "%-7s :%-5s %-44s OK %6s  \"%s\"  serves=[%s]\n" "$host" "$port" "$model" "$dt" "$txt" "$served"; ((pass++))
  else
    printf "%-7s :%-5s %-44s UP-but-chat-FAILED serves=[%s]\n" "$host" "$port" "$model" "$served"; ((fail++))
  fi
done < "$here/endpoints.txt"
echo "pass=$pass fail=$fail off=$skip"
[[ $fail -eq 0 ]]
