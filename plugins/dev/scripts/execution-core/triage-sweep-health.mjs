// triage-sweep-health.mjs — per-team sustained held-sweep escalation (CAT-82).
// SIBLINGS: replica-health.mjs and reconcile-health.mjs deliberately remain
// separate because their degraded predicates and latch semantics differ.
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  getTriageSweepHealthDir,
  TRIAGE_SWEEP_HELD_ALERT_THRESHOLD,
  TRIAGE_SWEEP_HELD_REFRESH_MS,
  log,
} from "./config.mjs";
import {
  appendTriageSweepHealthEvent as defaultAppendEvent,
  TRIAGE_HELD_ACTION,
  TRIAGE_RECOVERED_ACTION,
} from "./triage-sweep-health-event.mjs";

const health = new Map();

function healthPath(team) {
  return join(getTriageSweepHealthDir(), `${team}.json`);
}

function defaultReadMarker(team) {
  try {
    const parsed = JSON.parse(readFileSync(healthPath(team), "utf8"));
    return {
      consecutiveHeld: typeof parsed.consecutiveHeld === "number" ? parsed.consecutiveHeld : 0,
      alerting: parsed.alerting === true,
      // CAT-82 (Codex P1): hydrate the last held-emit stamp so a daemon restart
      // mid-outage does not reset the refresh clock (which would re-emit
      // immediately on the first post-restart sweep, then again a full interval
      // later). A marker written before this field existed hydrates as null and
      // refreshes on the next held sweep — the fail-safe direction.
      lastHeldEmitMs:
        typeof parsed.lastHeldEmitMs === "number" && Number.isFinite(parsed.lastHeldEmitMs)
          ? parsed.lastHeldEmitMs
          : null,
    };
  } catch {
    return null;
  }
}

function ensureEntry(team, readMarker) {
  let entry = health.get(team);
  if (!entry) {
    entry = readMarker(team) ?? { consecutiveHeld: 0, alerting: false, lastHeldEmitMs: null };
    health.set(team, entry);
  }
  return entry;
}

function defaultWriteMarker(team, state) {
  const dir = getTriageSweepHealthDir();
  mkdirSync(dir, { recursive: true });
  const path = healthPath(team);
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, `${JSON.stringify({ team, ...state, updatedAt: new Date().toISOString() }, null, 2)}\n`);
  renameSync(tmp, path);
}

export function recordTriageSweep(team, { considered = 0, heldDelegateUnreadable = 0 } = {}, {
  appendEvent = defaultAppendEvent,
  readMarker = defaultReadMarker,
  writeMarker = defaultWriteMarker,
  threshold = TRIAGE_SWEEP_HELD_ALERT_THRESHOLD,
  refreshMs = TRIAGE_SWEEP_HELD_REFRESH_MS,
  now = () => Date.now(),
} = {}) {
  try {
    const entry = ensureEntry(team, readMarker);
    // CAT-82 (review R1): a sweep with NO candidates is absence of evidence, not
    // evidence of recovery. Falling into the healthy branch here cleared a latched
    // outage the moment the queue emptied for an unrelated reason (every candidate
    // parked at TRIAGE_DISPATCH_CAP, or filtered by hasTriageArtifact) — emitting a
    // spurious monitor.triage.recovered.<team> mid-outage and deleting the team from
    // board-health's triageSweepHeld ring, which is the corroboration
    // checkTriageProduction depends on. Leave the streak and the latch untouched.
    if (considered === 0) return;
    const fullyHeld = heldDelegateUnreadable === considered;
    if (fullyHeld) {
      entry.consecutiveHeld += 1;
      // CAT-82 (Codex P1): emit on the rising edge AND refresh periodically while
      // the latch stays held. The durable marker below survives anything, but
      // board-health's corroboration is rebuilt from the BOUNDED event tail (the
      // current month's last 800 events), so an edge-only emit goes dark the moment
      // that single event is evicted — or instantly at a UTC month rollover, which
      // starts an empty file. With no completion in the new tail either,
      // checkTriageProduction then reports observable:false and stops escalating a
      // still-running outage. Re-emitting keeps the evidence inside the window.
      const nowMs = now();
      const stale = entry.lastHeldEmitMs == null || nowMs - entry.lastHeldEmitMs >= refreshMs;
      if (entry.consecutiveHeld >= threshold && (!entry.alerting || stale)) {
        const appended = appendEvent({ team, action: TRIAGE_HELD_ACTION, consecutiveHeld: entry.consecutiveHeld, considered, heldDelegateUnreadable });
        // A failed append must not advance the refresh clock — otherwise a transient
        // write error would suppress re-emission for a whole interval.
        if (appended !== false) {
          entry.alerting = true;
          entry.lastHeldEmitMs = nowMs;
        }
      }
    } else {
      entry.consecutiveHeld = 0;
      if (entry.alerting) {
        const appended = appendEvent({ team, action: TRIAGE_RECOVERED_ACTION, consecutiveHeld: 0, considered, heldDelegateUnreadable });
        if (appended !== false) {
          entry.alerting = false;
          entry.lastHeldEmitMs = null;
        }
      }
    }
    writeMarker(team, entry);
  } catch (err) {
    log.warn({ team, err: err.message }, "triage-sweep-health: update failed");
  }
}

export function resetTriageSweepHealth() {
  health.clear();
}
