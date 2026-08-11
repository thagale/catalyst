#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"; SUT="$ROOT/plugins/dev/scripts/audit-automerge-cascade.sh"
S="$(mktemp -d)"; trap 'rm -rf "$S"' EXIT
printf '%s\n' '["org/repo"]' >"$S/repos.json"
cat >"$S/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == 'pr list' ]]; then
  echo '[{"number":15,"mergedAt":"2026-08-10T10:00:00Z","mergedBy":{"login":"app/github-actions"},"mergeCommit":{"oid":"bad"}},{"number":48,"mergedAt":"2026-08-10T11:00:00Z","mergedBy":{"login":"thagale"},"mergeCommit":{"oid":"good"}}]'
elif [[ "$1 $2" == 'run list' ]]; then echo '[{"headSha":"good"},{"headSha":"unrelated"}]'; else exit 1; fi
EOF
chmod +x "$S/gh"
set +e; CATALYST_AUTOMERGE_GH_BIN="$S/gh" "$SUT" --verify --since 7d --repos "$S/repos.json" >"$S/out"; rc=$?; set -e
grep -qF $'org/repo\t#15\tapp/github-actions\tsuppressed\tbad' "$S/out" || exit 1
grep -qF $'org/repo\t#48\tthagale\tcascaded\tgood' "$S/out" || exit 1
[[ $rc -eq 10 ]] || exit 1
set +e; "$SUT" --verify --since nonsense --repos "$S/repos.json" >/dev/null 2>&1; rc=$?; set -e
[[ $rc -eq 2 ]] || exit 1
cat >"$S/fail-gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$S/fail-gh"
set +e; CATALYST_AUTOMERGE_GH_BIN="$S/fail-gh" "$SUT" --verify --since 7d --repos "$S/repos.json" >"$S/failed"; rc=$?; set -e
[[ $rc -eq 5 ]] || exit 1
grep -qF $'org/repo\t\tunknown\tunknown' "$S/failed" || exit 1
echo '6 passed, 0 failed'
