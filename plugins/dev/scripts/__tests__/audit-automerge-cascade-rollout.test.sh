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
    run: |
      gh pr merge "$PR_URL" --auto --squash
EOF
cat >"$S/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == api ]]; then p="$2"; repo="${p#repos/}"; repo="${repo%%/contents/*}"; rest="${p#*contents/.github/workflows}"; if [[ -z "$rest" ]]; then find "$GH_FIXTURE_DIR/$repo" -type f -maxdepth 1 | sed "s|$GH_FIXTURE_DIR/$repo/|.github/workflows/|"; else f="$GH_FIXTURE_DIR/$repo/${rest#/}"; [[ -f "$f" ]] || exit 1; base64 <"$f"; fi
elif [[ "$1 $2" == 'pr list' ]]; then echo '[]'
elif [[ "$1 $2" == 'repo view' ]]; then echo "$GH_CLONE_URL"
elif [[ "$1 $2" == 'pr create' ]]; then echo "$*" >>"$GH_CALLS"; echo 'https://example.test/pr/1'
else echo "$*" >>"$GH_CALLS"; exit 1; fi
EOF
chmod +x "$S/gh"; echo '["org/repo"]' >"$S/repos.json"; : >"$S/calls"
GH_FIXTURE_DIR="$S/f" GH_CALLS="$S/calls" CATALYST_AUTOMERGE_GH_BIN="$S/gh" "$SUT" --rollout --repos "$S/repos.json" >"$S/out"
grep -qF 'dry-run diff for' "$S/out" || exit 1
[[ ! -s "$S/calls" ]] || exit 1

# The mutating path uses a local bare remote and opens exactly one recorded PR.
git init -q -b main "$S/source"
git -C "$S/source" config user.name test; git -C "$S/source" config user.email test@example.test
mkdir -p "$S/source/.github/workflows"; cp "$S/f/org/repo/auto-merge.yml" "$S/source/.github/workflows/auto-merge.yml"
git -C "$S/source" add .; git -C "$S/source" -c commit.gpgsign=false commit -q -m init
git init -q --bare -b main "$S/origin.git"; git -C "$S/source" remote add origin "$S/origin.git"; git -C "$S/source" push -q origin main
: >"$S/calls"
GH_FIXTURE_DIR="$S/f" GH_CALLS="$S/calls" GH_CLONE_URL="$S/origin.git" CATALYST_AUTOMERGE_GH_BIN="$S/gh" "$SUT" --rollout --fix --repos "$S/repos.json" >"$S/fix-out"
grep -qF 'org/repo: opened' "$S/fix-out" || exit 1
[[ "$(grep -c '^pr create' "$S/calls")" -eq 1 ]] || exit 1
git --git-dir="$S/origin.git" show catalyst/cat-151-automerge-cascade:.github/workflows/auto-merge.yml >"$S/patched.yml"
grep -qF 'AUTOMERGE_PAT:' "$S/patched.yml" || exit 1
ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' "$S/patched.yml" || exit 1
echo '6 passed, 0 failed'
