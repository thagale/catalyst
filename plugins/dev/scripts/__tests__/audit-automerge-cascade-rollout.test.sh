#!/usr/bin/env bash
# Rollout's safety contract is tested without network access: default mode is dry-run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"; SUT="$ROOT/plugins/dev/scripts/audit-automerge-cascade.sh"
S="$(mktemp -d)"; trap 'rm -rf "$S"' EXIT; mkdir -p "$S/f/org/repo"
cat >"$S/f/org/repo/auto-merge.yml" <<'EOF'
jobs:
  merge:
    env:
      GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    run: gh pr merge "$PR_URL" --auto --squash
EOF
cat >"$S/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == api ]]; then p="$2"; repo="${p#repos/}"; repo="${repo%%/contents/*}"; rest="${p#*contents/.github/workflows}"; if [[ -z "$rest" ]]; then find "$GH_FIXTURE_DIR/$repo" -type f -maxdepth 1 | sed "s|$GH_FIXTURE_DIR/$repo/|.github/workflows/|"; else f="$GH_FIXTURE_DIR/$repo/${rest#/}"; [[ -f "$f" ]] || exit 1; base64 <"$f"; fi
elif [[ "$1 $2" == 'pr list' ]]; then echo '[]'; else echo "$*" >>"$GH_CALLS"; exit 1; fi
EOF
chmod +x "$S/gh"; echo '["org/repo"]' >"$S/repos.json"; : >"$S/calls"
GH_FIXTURE_DIR="$S/f" GH_CALLS="$S/calls" CATALYST_AUTOMERGE_GH_BIN="$S/gh" "$SUT" --rollout --repos "$S/repos.json" >"$S/out"
grep -qF 'dry-run would patch' "$S/out" || exit 1
[[ ! -s "$S/calls" ]] || exit 1
echo '2 passed, 0 failed'
