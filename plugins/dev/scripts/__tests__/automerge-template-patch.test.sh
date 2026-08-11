#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"; SUT="$ROOT/plugins/dev/scripts/audit-automerge-cascade.sh"
S="$(mktemp -d)"; trap 'rm -rf "$S"' EXIT
cat >"$S/workflow.yml" <<'EOF'
name: Own PRs
jobs:
  policy:
    runs-on: ubuntu-latest
    steps:
      - run: ./validate-author.sh
  auto-merge:
    if: github.actor == 'thagale'
    needs: policy
    steps:
      - env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh pr merge "$PR_URL" --auto --squash
EOF
"$SUT" --patch-workflow "$S/workflow.yml" --secret-name FLEET_PAT | grep -q patched || exit 1
grep -qF "if: github.actor == 'thagale'" "$S/workflow.yml" || exit 1
grep -qF 'run: ./validate-author.sh' "$S/workflow.yml" || exit 1
grep -qF 'needs: policy' "$S/workflow.yml" || exit 1
grep -qF 'secrets.FLEET_PAT' "$S/workflow.yml" || exit 1
"$SUT" --patch-workflow "$S/workflow.yml" --secret-name FLEET_PAT | grep -q already-current || exit 1
echo broken >"$S/broken.yml"
set +e; "$SUT" --patch-workflow "$S/broken.yml" >/dev/null; rc=$?; set -e
[[ $rc -eq 3 ]] || exit 1

# A prose comment mentioning the command is ignored; the real merge step is patched.
cat >"$S/comment.yml" <<'EOF'
# This workflow uses gh pr merge --auto after its policy gate.
jobs:
  merge:
    steps:
      - env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh pr merge "$PR_URL" --auto --squash
EOF
"$SUT" --patch-workflow "$S/comment.yml" >/dev/null || exit 1
grep -qF '# This workflow uses gh pr merge --auto' "$S/comment.yml" || exit 1

# Only the token belonging to the merge step is rewritten.
cat >"$S/two-step.yml" <<'EOF'
jobs:
  merge:
    steps:
      - env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh pr edit "$PR_URL" --add-label ready
      - env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh pr merge "$PR_URL" --auto --squash
EOF
"$SUT" --patch-workflow "$S/two-step.yml" >/dev/null || exit 1
[[ "$(grep -cF 'GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}' "$S/two-step.yml")" -eq 1 ]] || exit 1

# Folded scalars are refused because injected shell newlines would be folded.
cat >"$S/folded.yml" <<'EOF'
env:
  GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
run: >
  gh pr merge "$PR_URL" --auto --squash
EOF
set +e; "$SUT" --patch-workflow "$S/folded.yml" >/dev/null; rc=$?; set -e
[[ $rc -eq 3 ]] || exit 1

# Inline run commands are refused rather than rewritten into invalid YAML.
cat >"$S/inline.yml" <<'EOF'
env:
  GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
run: gh pr merge "$PR_URL" --auto --squash
EOF
set +e; "$SUT" --patch-workflow "$S/inline.yml" >/dev/null; rc=$?; set -e
[[ $rc -eq 3 ]] || exit 1

# Explicit dry-run prints the diff but leaves the workflow byte-identical.
cat >"$S/dry.yml" <<'EOF'
env:
  GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
run: |
  gh pr merge "$PR_URL" --auto --squash
EOF
cp "$S/dry.yml" "$S/dry.before"
"$SUT" --patch-workflow "$S/dry.yml" --dry-run | grep -q would-patch || exit 1
cmp -s "$S/dry.before" "$S/dry.yml" || exit 1

# The surgical patcher and canonical rendered template must not drift.
cat >"$S/canonical-old.yml" <<'EOF'
name: Auto-Merge PRs

on:
  pull_request:
    types: [opened, reopened, ready_for_review]

permissions:
  contents: write
  pull-requests: write

jobs:
  auto-merge:
    if: github.event.pull_request.draft == false
    runs-on: ubuntu-latest
    steps:
      - name: Enable auto-merge
        env:
          PR_URL: ${{ github.event.pull_request.html_url }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh pr merge "$PR_URL" --auto --squash
EOF
"$SUT" --patch-workflow "$S/canonical-old.yml" >/dev/null || exit 1
sed 's/{{SECRET_NAME}}/AUTOMERGE_PAT/g' "$ROOT/plugins/dev/templates/github-actions/auto-merge.yml.template" >"$S/rendered.yml"
cmp -s "$S/canonical-old.yml" "$S/rendered.yml" || exit 1
echo '16 passed, 0 failed'
