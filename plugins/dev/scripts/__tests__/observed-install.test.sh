#!/usr/bin/env bash
# observed-install.test.sh — contract tests for observed-install.sh (CAT-299).
# No network: uses the CATALYST_OBSERVED_INSTALL_INJECT seam for endpoints.
# Run: bash plugins/dev/scripts/__tests__/observed-install.test.sh
set -u
set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$SCRIPT_DIR/../observed-install.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export CATALYST_SUPPLY_CHAIN_LOG="$TMP/supply-chain.log"
PASS=0; FAIL=0; FAILURES=()
assert_eq() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); echo "  ok: $1"; else FAIL=$((FAIL+1)); FAILURES+=("$1: expected='$2' actual='$3'"); echo "  FAIL: $1 (expected='$2' actual='$3')"; fi; }

echo "1. exit code propagates, one JSON line appended"
"$BIN" --repo t1 --interval 0.1 -- sh -c 'exit 3' 2>/dev/null; rc=$?
assert_eq "exit code propagated" "3" "$rc"
assert_eq "one line written" "1" "$(wc -l < "$CATALYST_SUPPLY_CHAIN_LOG" | tr -d ' ')"
line="$(tail -1 "$CATALYST_SUPPLY_CHAIN_LOG")"
assert_eq "valid JSON" "0" "$(printf '%s' "$line" | jq -e . >/dev/null 2>&1; echo $?)"
assert_eq "repo field" "t1" "$(printf '%s' "$line" | jq -r .repo)"
assert_eq "exit field" "3" "$(printf '%s' "$line" | jq -r .exit)"
assert_eq "pino level WARN on failure" "40" "$(printf '%s' "$line" | jq -r .level)"
assert_eq "name is supply-chain" "supply-chain" "$(printf '%s' "$line" | jq -r .name)"
assert_eq "time is ms epoch" "true" "$(printf '%s' "$line" | jq '.time > 1600000000000')"

echo "2. clean install, no endpoints -> INFO, counts 0"
"$BIN" --repo t2 --interval 0.1 -- sh -c 'exit 0' 2>/dev/null; rc=$?
line="$(tail -1 "$CATALYST_SUPPLY_CHAIN_LOG")"
assert_eq "exit 0" "0" "$rc"
assert_eq "level INFO" "30" "$(printf '%s' "$line" | jq -r .level)"
assert_eq "endpoint_count 0" "0" "$(printf '%s' "$line" | jq -r .endpoint_count)"
assert_eq "unexpected_count 0" "0" "$(printf '%s' "$line" | jq -r .unexpected_count)"

echo "3. injected endpoints: literal-IP allowlist entry vs unexpected TEST-NET address"
CATALYST_OBSERVED_INSTALL_INJECT="127.0.0.1:443,198.51.100.7:8443" \
  "$BIN" --repo t3 --allow 127.0.0.1 --interval 0.1 -- sh -c 'exit 0' 2>"$TMP/err"; rc=$?
line="$(tail -1 "$CATALYST_SUPPLY_CHAIN_LOG")"
assert_eq "install exit unchanged without --fail-on-unexpected" "0" "$rc"
assert_eq "endpoint_count 2" "2" "$(printf '%s' "$line" | jq -r .endpoint_count)"
assert_eq "unexpected_count 1" "1" "$(printf '%s' "$line" | jq -r .unexpected_count)"
assert_eq "allowlisted ip marked known" "true" "$(printf '%s' "$line" | jq -r '.endpoints[] | select(.ip=="127.0.0.1") | .known')"
assert_eq "TEST-NET ip flagged unknown" "false" "$(printf '%s' "$line" | jq -r '.endpoints[] | select(.ip=="198.51.100.7") | .known')"
assert_eq "port parsed as number" "8443" "$(printf '%s' "$line" | jq -r '.endpoints[] | select(.ip=="198.51.100.7") | .port')"
assert_eq "level WARN on unexpected" "40" "$(printf '%s' "$line" | jq -r .level)"
assert_eq "stderr warns" "1" "$(grep -c 'unexpected endpoint' "$TMP/err")"

echo "4. --fail-on-unexpected turns a clean install into exit 97"
CATALYST_OBSERVED_INSTALL_INJECT="198.51.100.7:443" \
  "$BIN" --repo t4 --fail-on-unexpected --interval 0.1 -- sh -c 'exit 0' 2>/dev/null; rc=$?
assert_eq "exit 97" "97" "$rc"

echo "5. the install's own child processes are sampled (tree walk doesn't crash on a real tree)"
"$BIN" --repo t5 --interval 0.1 -- sh -c 'sleep 0.4 & wait' 2>/dev/null; rc=$?
assert_eq "exit 0 with a forked child" "0" "$rc"

echo "6. argument errors"
"$BIN" --repo x 2>/dev/null; assert_eq "no command -> 2" "2" "$?"
"$BIN" --bogus -- true 2>/dev/null; assert_eq "unknown flag -> 2" "2" "$?"

echo; echo "passed=$PASS failed=$FAIL"
for f in "${FAILURES[@]:-}"; do [[ -n "$f" ]] && echo "  - $f"; done
[[ $FAIL -eq 0 ]]
