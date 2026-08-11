#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"; STACK="$ROOT/plugins/dev/scripts/catalyst-stack"
TMP="$(mktemp -d)"; trap 'launchctl bootout "gui/$(id -u)/ai.coalesce.catalyst-event-mirror" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home/catalyst"
cat > "$TMP/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/launchctl"
for c in catalyst-broker catalyst-monitor catalyst-execution-core; do
  cat > "$TMP/bin/$c" <<EOF
#!/usr/bin/env bash
echo "$c \$*" >> "$TMP/calls"
[[ "\${1:-}" == status || "\${1:-}" == forward-status ]] && echo stopped
exit 0
EOF
  chmod +x "$TMP/bin/$c"
done
export HOME="$TMP/home" CATALYST_DIR="$TMP/home/catalyst" PATH="$TMP/bin:$PATH" CATALYST_NODE_CLASS=developer
fail=0
ok(){ "$@" || { echo "not ok: $*"; fail=$((fail+1)); }; }

ok "$STACK" stop
ok jq -e '.haltedAt and .host and .reason and .by' "$CATALYST_DIR/stack-halt.json"
EVENT_FILE="$CATALYST_DIR/events/$(date -u +%Y-%m).jsonl"
ok jq -e 'select(.attributes["event.name"] == "node.stack.halted")' "$EVENT_FILE"
rm -f "$CATALYST_DIR/stack-halt.json"; ok "$STACK" stop --no-halt; ok test ! -e "$CATALYST_DIR/stack-halt.json"
ok "$STACK" stop; : > "$TMP/calls"; ok "$STACK" start --supervised; ok test ! -s "$TMP/calls"
ok jq -e 'select(.attributes["event.name"] == "node.stack.start-suppressed") | .body.payload.ageSecs | numbers' "$EVENT_FILE"
: > "$TMP/calls"; ok "$STACK" start; ok test ! -e "$CATALYST_DIR/stack-halt.json"; ok test -s "$TMP/calls"
ok bash -c "'$STACK' status 2>&1 | grep -q supervision"
ok "$STACK" stop; ok "$STACK" restart; ok test ! -e "$CATALYST_DIR/stack-halt.json"
BAKE_ROOT="$ROOT"
GIT_DIR="$(git -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null || true)"
if [[ "$GIT_DIR" == */worktrees/* ]]; then
  BAKE_ROOT="$(dirname "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)")"
fi
ok bash -c "CATALYST_FORCE_BAKE_DIR='$BAKE_ROOT/plugins/dev/scripts' '$STACK' install-services --print 2>/dev/null | grep -q '<string>--supervised</string>'"
exit "$fail"
