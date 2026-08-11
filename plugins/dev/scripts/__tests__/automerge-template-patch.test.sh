#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"; SUT="$ROOT/plugins/dev/scripts/audit-automerge-cascade.sh"
S="$(mktemp -d)"; trap 'rm -rf "$S"' EXIT
cat >"$S/workflow.yml" <<'EOF'
name: Own PRs
jobs:
  auto-merge:
    if: github.actor == 'thagale'
    steps:
      - env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: gh pr merge "$PR_URL" --auto --squash
EOF
"$SUT" --patch-workflow "$S/workflow.yml" --secret-name FLEET_PAT | grep -q patched || exit 1
grep -qF "if: github.actor == 'thagale'" "$S/workflow.yml" || exit 1
grep -qF 'secrets.FLEET_PAT' "$S/workflow.yml" || exit 1
"$SUT" --patch-workflow "$S/workflow.yml" --secret-name FLEET_PAT | grep -q already-current || exit 1
echo broken >"$S/broken.yml"
set +e; "$SUT" --patch-workflow "$S/broken.yml" >/dev/null; rc=$?; set -e
[[ $rc -eq 3 ]] || exit 1
echo '5 passed, 0 failed'
