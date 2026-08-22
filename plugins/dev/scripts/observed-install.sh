#!/usr/bin/env bash
# observed-install.sh — run a dependency install and record where it talked to.
#
# (CAT-299 / dispensa ADR-0014 §8) Detection layer for dependency-install
# network activity. Wraps ANY install command, samples the established TCP
# connections of the install's whole process tree while it runs, classifies
# each remote endpoint against a forward-resolved allowlist of registries/CDNs,
# and appends ONE pino-shaped JSON line to the supply-chain log that Alloy
# ships to Loki as the `catalyst.supply-chain` stream (see
# log-shipper/config.alloy and the sensing-substrate skill for the LogQL).
#
# The install's exit code is propagated unchanged; observation never alters
# the install. Pass --fail-on-unexpected to make an unlisted endpoint fatal.
#
# Usage:
#   observed-install.sh [--repo NAME] [--allow host,host,...] [--log PATH]
#                       [--interval SEC] [--fail-on-unexpected] -- <install command...>
#   observed-install.sh -- pnpm install --frozen-lockfile
#   observed-install.sh --fail-on-unexpected -- npm ci
#
# Env:
#   CATALYST_DIR                 catalyst home (default ~/catalyst)
#   CATALYST_SUPPLY_CHAIN_LOG    log path (default $CATALYST_DIR/supply-chain.log)
#   CATALYST_INSTALL_ALLOW       extra allowlist hosts, comma-separated
#
# Portability: macOS + Linux. Needs lsof, ps; uses dig/getent/host for
# resolution when available (best-effort — an unresolvable allowlist host just
# contributes no IPs, and the endpoint shows up as unexpected). Literal IPs in
# --allow / CATALYST_INSTALL_ALLOW are accepted as-is (private mirrors).

set -uo pipefail

DEFAULT_ALLOW="registry.npmjs.org,registry.yarnpkg.com,github.com,api.github.com,codeload.github.com,objects.githubusercontent.com,raw.githubusercontent.com,crates.io,static.crates.io,index.crates.io,nodejs.org,get.pnpm.io,bun.sh,registry.npmmirror.com"

CATALYST_DIR="${CATALYST_DIR:-$HOME/catalyst}"
LOG="${CATALYST_SUPPLY_CHAIN_LOG:-$CATALYST_DIR/supply-chain.log}"
REPO=""
ALLOW="$DEFAULT_ALLOW${CATALYST_INSTALL_ALLOW:+,$CATALYST_INSTALL_ALLOW}"
INTERVAL="0.5"
FAIL_ON_UNEXPECTED=0

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
    --allow) ALLOW="$ALLOW,${2:?--allow needs a value}"; shift 2 ;;
    --log) LOG="${2:?--log needs a value}"; shift 2 ;;
    --interval) INTERVAL="${2:?--interval needs a value}"; shift 2 ;;
    --fail-on-unexpected) FAIL_ON_UNEXPECTED=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) echo "observed-install: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ $# -gt 0 ]] || { echo "observed-install: no command given after --" >&2; exit 2; }

if [[ -z "$REPO" ]]; then
  # Prefer the remote name (a worktree's directory basename is the branch slug).
  REPO="$(basename -s .git "$(git remote get-url origin 2>/dev/null || true)" 2>/dev/null || true)"
  [[ -n "$REPO" ]] || REPO="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"
fi
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"

# ── process-tree descendants (portable: ps -axo pid=,ppid=) ───────────────────
descendants() {
  local root="$1"
  ps -axo pid=,ppid= 2>/dev/null | awk -v root="$root" '
    { pp[$1]=$2 }
    END {
      for (p in pp) {
        q=p; while (q in pp) { if (pp[q]==root) { print p; break } ; q=pp[q]; if (q==root) break }
      }
    }'
}

# ── sampler: collect unique "ip:port" remote endpoints of the tree ─────────────
OBS_FILE="$(mktemp)"
trap 'rm -f "$OBS_FILE"' EXIT

sample_once() {
  local pids
  # The root pid itself PLUS every descendant: a package manager opens sockets
  # from its own process as well as from spawned node/git/curl children (and a
  # `sh -c '<one command>'` execs straight into that command, leaving no
  # descendants at all). Never call lsof with an empty -p list -- it would
  # report every process on the host.
  pids="$1,$(descendants "$1" | tr '\n' ',')"
  pids="${pids%,}"
  # NAME column is "src->dst" and, with -s, lsof appends "(ESTABLISHED)" as the
  # final field -- so find the field that carries "->" rather than taking $NF.
  lsof -nP -iTCP -sTCP:ESTABLISHED -a -p "$pids" 2>/dev/null \
    | awk 'NR>1 { for (i=1; i<=NF; i++) if ($i ~ /->/) { n=$i; sub(/^.*->/, "", n); if (n ~ /:[0-9]+$/) print n } }' \
    >> "$OBS_FILE" || true
}

START_S=$(date +%s)
START_MS=$(( START_S * 1000 ))
"$@" &
CHILD=$!
while kill -0 "$CHILD" 2>/dev/null; do
  sample_once "$CHILD"
  sleep "$INTERVAL"
done
wait "$CHILD"; RC=$?
END_S=$(date +%s)

# Test seam: inject observations without real network (used by the test suite).
if [[ -n "${CATALYST_OBSERVED_INSTALL_INJECT:-}" ]]; then
  printf '%s\n' "${CATALYST_OBSERVED_INSTALL_INJECT//,/$'\n'}" >> "$OBS_FILE"
fi

# ── resolve allowlist → IPs (best effort) ─────────────────────────────────────
resolve() {
  local h="$1"
  # A literal IP in the allowlist (e.g. a private registry mirror) is used as-is.
  if [[ "$h" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$h" == *:*:* ]]; then printf '%s\n' "$h"; return; fi
  if command -v dig >/dev/null 2>&1; then dig +short +time=2 +tries=1 A "$h" 2>/dev/null; dig +short +time=2 +tries=1 AAAA "$h" 2>/dev/null
  elif command -v getent >/dev/null 2>&1; then getent ahosts "$h" 2>/dev/null | awk '{print $1}'
  elif command -v host >/dev/null 2>&1; then host -W 2 "$h" 2>/dev/null | awk '/has (IPv6 )?address/ {print $NF}'
  fi | grep -E '^[0-9a-fA-F.:]+$' || true
}
ALLOW_MAP="$(mktemp)"; trap 'rm -f "$OBS_FILE" "$ALLOW_MAP"' EXIT
IFS=',' read -r -a ALLOW_HOSTS <<< "$ALLOW"
if [[ -s "$OBS_FILE" ]]; then
  for h in "${ALLOW_HOSTS[@]}"; do
    [[ -n "$h" ]] || continue
    while IFS= read -r ip; do [[ -n "$ip" ]] && printf '%s %s\n' "$ip" "$h"; done < <(resolve "$h")
  done >> "$ALLOW_MAP"
fi

# ── classify + emit ───────────────────────────────────────────────────────────
ENDPOINTS_JSON="$(sort -u "$OBS_FILE" | awk -v map="$ALLOW_MAP" '
  BEGIN { while ((getline l < map) > 0) { split(l, a, " "); known[a[1]]=a[2] } }
  NF {
    ep=$0; port=ep; sub(/^.*:/, "", port); ip=ep; sub(/:[0-9]+$/, "", ip); gsub(/^\[|\]$/, "", ip)
    h=(ip in known) ? known[ip] : ""
    printf "%s{\"ip\":\"%s\",\"port\":%s,\"host\":\"%s\",\"known\":%s}", (n++ ? "," : ""), ip, port, h, (h != "" ? "true" : "false")
  }
  END { printf "" }')"
UNEXPECTED_COUNT=$(printf '%s' "$ENDPOINTS_JSON" | grep -o '"known":false' | wc -l | tr -d ' ')
TOTAL_COUNT=$(sort -u "$OBS_FILE" | grep -c . || true)

LEVEL=30
[[ "$UNEXPECTED_COUNT" -gt 0 || "$RC" -ne 0 ]] && LEVEL=40
CMD_JSON="$(printf '%s' "$*" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '"%s"' "$*")"

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
printf '{"level":%s,"time":%s,"pid":%s,"hostname":"%s","name":"supply-chain","msg":"dependency install observed","repo":"%s","cmd":%s,"exit":%s,"duration_s":%s,"endpoint_count":%s,"unexpected_count":%s,"endpoints":[%s]}\n' \
  "$LEVEL" "$START_MS" "$$" "$HOSTNAME_SHORT" "$REPO" "$CMD_JSON" "$RC" "$(( END_S - START_S ))" "$TOTAL_COUNT" "$UNEXPECTED_COUNT" "$ENDPOINTS_JSON" >> "$LOG" \
  || echo "observed-install: WARN could not append to $LOG" >&2

if [[ "$UNEXPECTED_COUNT" -gt 0 ]]; then
  echo "observed-install: WARN $UNEXPECTED_COUNT unexpected endpoint(s) during install of $REPO (see $LOG)" >&2
  [[ "$FAIL_ON_UNEXPECTED" -eq 1 && "$RC" -eq 0 ]] && RC=97
fi
exit "$RC"
