#!/usr/bin/env bash
# Durable operator-intent marker for catalyst-stack supervision (CAT-163).

STACK_HALT_FILE="${CATALYST_DIR:-$HOME/catalyst}/stack-halt.json"
STACK_HALT_TTL_SECS="${CATALYST_STACK_HALT_TTL_SECS:-86400}"
STACK_HALT_STATE="absent"
STACK_HALT_AGE_SECS=0
STACK_HALT_HALTED_AT=""
STACK_HALT_REASON=""
STACK_HALT_TTL_EFFECTIVE="$STACK_HALT_TTL_SECS"

stack_halt_write() {
  local reason="${1:-operator requested stop}" dir tmp now host by
  dir="$(dirname "$STACK_HALT_FILE")"; mkdir -p "$dir" || return 1
  tmp="${STACK_HALT_FILE}.tmp.$$"; now="$(date +%s)"
  host="${CATALYST_HOST_NAME:-$(hostname -s 2>/dev/null || hostname)}"
  by="${USER:-$(id -un 2>/dev/null || echo unknown)}"
  jq -nc --argjson haltedAt "$now" --arg host "$host" --arg reason "$reason" \
    --arg by "$by" --argjson ttlSecs "$STACK_HALT_TTL_SECS" \
    '{haltedAt:$haltedAt,host:$host,reason:$reason,by:$by,ttlSecs:$ttlSecs}' > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$STACK_HALT_FILE"
}

stack_halt_clear() { rm -f "$STACK_HALT_FILE"; }

stack_halt_active() {
  STACK_HALT_STATE="absent"; STACK_HALT_AGE_SECS=0; STACK_HALT_HALTED_AT=""; STACK_HALT_REASON=""; STACK_HALT_TTL_EFFECTIVE="$STACK_HALT_TTL_SECS"
  [[ -f "$STACK_HALT_FILE" ]] || return 1
  local now halted ttl
  if ! jq -e '.haltedAt|numbers' "$STACK_HALT_FILE" >/dev/null 2>&1; then
    STACK_HALT_STATE="malformed"
    mv "$STACK_HALT_FILE" "${STACK_HALT_FILE}.invalid.$(date +%s)" 2>/dev/null || true
    return 1
  fi
  now="$(date +%s)"; halted="$(jq -r '.haltedAt' "$STACK_HALT_FILE")"
  ttl="$(jq -r '.ttlSecs // empty' "$STACK_HALT_FILE")"; [[ "$ttl" =~ ^[0-9]+$ ]] || ttl="$STACK_HALT_TTL_SECS"
  STACK_HALT_TTL_EFFECTIVE="$ttl"
  STACK_HALT_AGE_SECS=$((now - halted)); (( STACK_HALT_AGE_SECS < 0 )) && STACK_HALT_AGE_SECS=0
  STACK_HALT_HALTED_AT="$halted"; STACK_HALT_REASON="$(jq -r '.reason // "operator requested stop"' "$STACK_HALT_FILE")"
  if (( STACK_HALT_AGE_SECS >= ttl )); then STACK_HALT_STATE="expired"; return 1; fi
  STACK_HALT_STATE="active"; return 0
}

stack_halt_describe() {
  if stack_halt_active; then
    printf 'halted by operator at epoch %s (reason: %s, %ss remaining)' "$STACK_HALT_HALTED_AT" "$STACK_HALT_REASON" "$((STACK_HALT_TTL_EFFECTIVE - STACK_HALT_AGE_SECS))"
  else
    printf 'active'
  fi
}
