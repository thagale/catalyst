#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
LIB="${REPO_ROOT}/plugins/dev/scripts/lib/escalate-merge-permission.sh"
SKILL="${REPO_ROOT}/plugins/dev/skills/phase-monitor-merge/SKILL.md"
FAILURES=0; PASSES=0
pass() { PASSES=$((PASSES+1)); echo "  PASS: $1"; }
fail() { FAILURES=$((FAILURES+1)); echo "  FAIL: $1"; }
assert_eq() { [[ "$1" == "$2" ]] && pass "$3" || fail "$3 — expected '$2', got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] && pass "$3" || fail "$3 — '$2' not found"; }
TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT
source "$LIB"
mk_gh() { local dir="$TMPROOT/bin.$RANDOM"; mkdir -p "$dir"; { echo '#!/usr/bin/env bash'; printf 'printf %%s %q\n' "$1"; echo "exit $2"; } > "$dir/gh"; chmod +x "$dir/gh"; echo "$dir"; }
probe_with() { local bin; bin="$(mk_gh "$1" "$2")"; PATH="$bin:$PATH" merge_permission_probe owner/repo; }
assert_eq "$(probe_with '{"push":false,"maintain":false,"admin":false}' 0)" denied "read-only grant"
assert_eq "$(probe_with '{"push":true,"maintain":false,"admin":false}' 0)" ok "push grant"
assert_eq "$(probe_with '{"push":false,"maintain":false,"admin":true}' 0)" ok "admin grant"
assert_eq "$(probe_with '' 1)" unknown "gh failure fails open"
assert_eq "$(probe_with '{}' 0)" unknown "missing permissions fails open"
assert_denial() { if merge_denial_is_permission "$1"; then assert_eq 0 "$2" "$3"; else assert_eq 1 "$2" "$3"; fi; }
assert_denial 'GraphQL: user does not have the correct permissions to execute `MergePullRequest`' 0 "GraphQL denial"
assert_denial 'HTTP 403: Must have admin rights to Repository.' 0 "admin denial"
assert_denial 'GraphQL: Pull request is not mergeable (mergePullRequest)' 1 "plain unmergeable"
assert_denial 'HTTP 502: Bad gateway' 1 "transient failure"
BODY="$(cat "$SKILL")"
assert_contains "$BODY" "merge_permission_probe" "preflight wired"
assert_contains "$BODY" "merge_denial_is_permission" "call-site classifier wired"
PRE_LINE="$(grep -n 'merge_permission_probe' "$SKILL" | head -1 | cut -d: -f1)"
MERGE_LINE="$(grep -n 'if ! gh pr merge' "$SKILL" | head -1 | cut -d: -f1)"
[[ "$PRE_LINE" -lt "$MERGE_LINE" ]] && pass "preflight precedes merge" || fail "preflight ordering"
echo "passed=$PASSES failed=$FAILURES"
[[ "$FAILURES" -eq 0 ]]
