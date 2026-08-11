#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"; STACK="$ROOT/plugins/dev/scripts/catalyst-stack"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home/catalyst"
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
rm -f "$CATALYST_DIR/stack-halt.json"; ok "$STACK" stop --no-halt; ok test ! -e "$CATALYST_DIR/stack-halt.json"
ok "$STACK" stop; : > "$TMP/calls"; ok "$STACK" start --supervised; ok test ! -s "$TMP/calls"
: > "$TMP/calls"; ok "$STACK" start; ok test ! -e "$CATALYST_DIR/stack-halt.json"; ok test -s "$TMP/calls"
ok "$STACK" stop; ok "$STACK" restart; ok test ! -e "$CATALYST_DIR/stack-halt.json"
ok bash -c "CATALYST_FORCE_BAKE_DIR='/Users/thagale/catalyst/plugin-source/plugins/dev/scripts' '$STACK' install-services --print 2>/dev/null | grep -q '<string>--supervised</string>'"
exit "$fail"
