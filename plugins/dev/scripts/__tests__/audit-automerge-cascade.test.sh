#!/usr/bin/env bash
# Offline tests for audit-automerge-cascade.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SUT="$ROOT/plugins/dev/scripts/audit-automerge-cascade.sh"
SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT
PASS=0 FAIL=0
check() { local name="$1"; shift; if "$@" >"$SCRATCH/check.out" 2>&1; then PASS=$((PASS+1)); echo "  PASS: $name"; else FAIL=$((FAIL+1)); echo "  FAIL: $name"; sed 's/^/    /' "$SCRATCH/check.out"; fi; }
contains() { grep -qF "$2" "$1"; }

mkdir -p "$SCRATCH/fixtures/org/vanity" "$SCRATCH/fixtures/org/fixed" "$SCRATCH/fixtures/org/none"
cat >"$SCRATCH/fixtures/org/vanity/auto-merge.yml" <<'EOF'
name: Auto-Merge
jobs:
  merge:
    env:
      GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    run: gh pr merge "$PR_URL" --auto --squash
EOF
cat >"$SCRATCH/fixtures/org/vanity/ci.yml" <<'EOF'
on:
  push:
    branches: [main]
EOF
sed 's/secrets.GITHUB_TOKEN/secrets.AUTOMERGE_PAT/' "$SCRATCH/fixtures/org/vanity/auto-merge.yml" >"$SCRATCH/fixtures/org/fixed/auto-merge.yml"
cat >"$SCRATCH/gh" <<'EOF'
#!/usr/bin/env bash
set -u
root="${GH_FIXTURE_DIR:?}"
if [[ "$1" == api ]]; then
  p="$2"; repo="${p#repos/}"; repo="${repo%%/contents/*}"; rest="${p#*contents/.github/workflows}"
  if [[ -z "$rest" ]]; then
    d="$root/$repo"; [[ -d "$d" ]] || exit 1
    find "$d" -type f -name '*.yml' -maxdepth 1 -print | sed "s|$d/|.github/workflows/|"
  else
    f="$root/$repo/${rest#/}"; [[ -f "$f" ]] || exit 1
    base64 <"$f"
  fi
else exit 1
fi
EOF
chmod +x "$SCRATCH/gh"
printf '%s\n' '{"org/vanity":"VAN","org/fixed":"FIX","org/none":"NON"}' >"$SCRATCH/repos.json"
set +e
GH_FIXTURE_DIR="$SCRATCH/fixtures" CATALYST_AUTOMERGE_GH_BIN="$SCRATCH/gh" "$SUT" --repos "$SCRATCH/repos.json" >"$SCRATCH/out"; rc=$?
set -e
check "suppressed is classified" contains "$SCRATCH/out" $'org/vanity\tauto-merge.yml\tsecrets.GITHUB_TOKEN\tsuppressed'
check "PAT is ok" contains "$SCRATCH/out" $'org/fixed\tauto-merge.yml\tsecrets.AUTOMERGE_PAT\tok'
check "missing workflow is not applicable" contains "$SCRATCH/out" $'org/none\t\t\tnot-applicable'
check "suppressed audit exits 10" test "$rc" = 10
GH_FIXTURE_DIR="$SCRATCH/fixtures" CATALYST_AUTOMERGE_GH_BIN="$SCRATCH/gh" "$SUT" --repos "$SCRATCH/repos.json" --json >"$SCRATCH/json" 2>/dev/null || true
check "JSON output parses" jq -e 'length == 3 and .[0].repo' "$SCRATCH/json"
check "docs contain verifier" grep -qF -- '--verify --since 7d' "$ROOT/docs/github-actions-token-cascade.md"
check "docs index links page" grep -qF 'github-actions-token-cascade.md' "$ROOT/docs/README.md"
echo "$PASS passed, $FAIL failed"; [[ $FAIL -eq 0 ]]
