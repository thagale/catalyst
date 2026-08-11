import { beforeEach, describe, expect, mock, test } from "bun:test";
import {
  recordTriageSweep,
  resetTriageSweepHealth,
} from "./triage-sweep-health.mjs";
import {
  buildTriageSweepHealthEvent,
  TRIAGE_HELD_ACTION,
  TRIAGE_RECOVERED_ACTION,
} from "./triage-sweep-health-event.mjs";

beforeEach(() => resetTriageSweepHealth());

// CAT-82 (Codex P1): the clock is injected so the periodic held-refresh is
// tested deterministically — never by sleeping.
const T0 = 1_700_000_000_000;
const REFRESH_MS = 15 * 60_000;

function harness(initial = null, appendResult = true) {
  let marker = initial;
  let clock = T0;
  const events = [];
  return {
    events,
    marker: () => marker,
    now: () => clock,
    advance: (ms) => { clock += ms; },
    deps: {
      threshold: 3,
      refreshMs: REFRESH_MS,
      now: () => clock,
      readMarker: () => marker,
      writeMarker: (_team, state) => { marker = { ...state }; },
      appendEvent: (event) => { events.push(event); return appendResult; },
    },
  };
}

describe("CAT-82 triage sweep health", () => {
  test("below threshold persists the streak without emitting", () => {
    const h = harness();
    recordTriageSweep("CAT", { considered: 3, heldDelegateUnreadable: 3 }, h.deps);
    recordTriageSweep("CAT", { considered: 3, heldDelegateUnreadable: 3 }, h.deps);
    expect(h.events).toHaveLength(0);
    expect(h.marker()).toEqual({ consecutiveHeld: 2, alerting: false, lastHeldEmitMs: null });
  });

  test("threshold raises exactly once while latched", () => {
    const h = harness();
    for (let i = 0; i < 5; i++) recordTriageSweep("CAT", { considered: 3, heldDelegateUnreadable: 3 }, h.deps);
    expect(h.events.map((e) => e.action)).toEqual([TRIAGE_HELD_ACTION]);
    expect(h.marker()).toEqual({ consecutiveHeld: 5, alerting: true, lastHeldEmitMs: T0 });
  });

  test("first healthy sweep recovers and later healthy sweeps stay quiet", () => {
    const h = harness({ consecutiveHeld: 3, alerting: true });
    recordTriageSweep("CAT", { considered: 3, heldDelegateUnreadable: 2 }, h.deps);
    recordTriageSweep("CAT", { considered: 3, heldDelegateUnreadable: 1 }, h.deps);
    expect(h.events.map((e) => e.action)).toEqual([TRIAGE_RECOVERED_ACTION]);
    expect(h.marker()).toEqual({ consecutiveHeld: 0, alerting: false, lastHeldEmitMs: null });
  });

  // Review R1: a candidate-less sweep is absence of evidence, not recovery.
  test("zero candidates leaves both the streak and a raised latch untouched", () => {
    const h = harness({ consecutiveHeld: 3, alerting: true });
    recordTriageSweep("CAT", { considered: 0, heldDelegateUnreadable: 0 }, h.deps);
    expect(h.events).toHaveLength(0);
    expect(h.marker()).toEqual({ consecutiveHeld: 3, alerting: true });
    // and the latch still recovers on a real, candidate-bearing healthy sweep
    recordTriageSweep("CAT", { considered: 2, heldDelegateUnreadable: 0 }, h.deps);
    expect(h.events.map((e) => e.action)).toEqual([TRIAGE_RECOVERED_ACTION]);
    expect(h.marker()).toEqual({ consecutiveHeld: 0, alerting: false, lastHeldEmitMs: null });
  });

  test("zero candidates does not restart an un-raised streak either", () => {
    const h = harness({ consecutiveHeld: 2, alerting: false });
    recordTriageSweep("CAT", { considered: 0, heldDelegateUnreadable: 0 }, h.deps);
    expect(h.marker()).toEqual({ consecutiveHeld: 2, alerting: false });
    recordTriageSweep("CAT", { considered: 1, heldDelegateUnreadable: 1 }, h.deps);
    expect(h.events.map((e) => e.action)).toEqual([TRIAGE_HELD_ACTION]);
  });

  test("failed event appends leave both raise and recovery latches retryable", () => {
    const raise = harness({ consecutiveHeld: 2, alerting: false }, false);
    recordTriageSweep("CAT", { considered: 1, heldDelegateUnreadable: 1 }, raise.deps);
    expect(raise.marker().alerting).toBe(false);
    recordTriageSweep("CAT", { considered: 1, heldDelegateUnreadable: 1 }, raise.deps);
    expect(raise.events).toHaveLength(2);

    resetTriageSweepHealth();
    const recover = harness({ consecutiveHeld: 3, alerting: true }, false);
    recordTriageSweep("CAT", { considered: 2, heldDelegateUnreadable: 0 }, recover.deps);
    expect(recover.marker().alerting).toBe(true);
    recordTriageSweep("CAT", { considered: 2, heldDelegateUnreadable: 0 }, recover.deps);
    expect(recover.events).toHaveLength(2);
  });

  test("durable markers resume a streak and teams remain independent", () => {
    const cat = harness({ consecutiveHeld: 2, alerting: false });
    const eng = harness();
    recordTriageSweep("CAT", { considered: 1, heldDelegateUnreadable: 1 }, cat.deps);
    recordTriageSweep("ENG", { considered: 1, heldDelegateUnreadable: 1 }, eng.deps);
    expect(cat.events).toHaveLength(1);
    expect(eng.events).toHaveLength(0);
    expect(eng.marker().consecutiveHeld).toBe(1);
  });

  // CAT-82 (Codex P1): the latch is durable, but board-health corroborates it from
  // the BOUNDED event tail. An edge-only emit goes dark once that one event is
  // evicted — or instantly at a UTC month rollover — leaving checkTriageProduction
  // with neither a completion nor held evidence: observable:false, and escalation
  // silently stops mid-outage. A still-held sweep must therefore refresh the event.
  test("a still-held sweep re-emits once the refresh interval elapses", () => {
    const h = harness();
    for (let i = 0; i < 3; i++) recordTriageSweep("CAT", { considered: 3, heldDelegateUnreadable: 3 }, h.deps);
    expect(h.events).toHaveLength(1);
    expect(h.marker().lastHeldEmitMs).toBe(T0);

    // Just short of the interval — still quiet.
    h.advance(REFRESH_MS - 1);
    recordTriageSweep("CAT", { considered: 3, heldDelegateUnreadable: 3 }, h.deps);
    expect(h.events).toHaveLength(1);

    // Crossing it refreshes the evidence, and the clock restarts from the re-emit.
    h.advance(1);
    recordTriageSweep("CAT", { considered: 3, heldDelegateUnreadable: 3 }, h.deps);
    expect(h.events).toHaveLength(2);
    expect(h.events.every((e) => e.action === TRIAGE_HELD_ACTION)).toBe(true);
    expect(h.marker().lastHeldEmitMs).toBe(T0 + REFRESH_MS);
    expect(h.marker().alerting).toBe(true);

    // The refresh carries the CURRENT streak, not the value at the rising edge.
    expect(h.events[1].consecutiveHeld).toBe(5);

    // Still one refresh per interval, not one per sweep.
    recordTriageSweep("CAT", { considered: 3, heldDelegateUnreadable: 3 }, h.deps);
    expect(h.events).toHaveLength(2);
  });

  test("a failed refresh append stays retryable on the next sweep", () => {
    const h = harness(
      // A latched team whose last emit is already one full interval old.
      { consecutiveHeld: 4, alerting: true, lastHeldEmitMs: T0 - REFRESH_MS },
      false
    );
    recordTriageSweep("CAT", { considered: 2, heldDelegateUnreadable: 2 }, h.deps);
    expect(h.events).toHaveLength(1);
    // The append failed, so the refresh clock must NOT advance — otherwise a
    // transient write error would suppress the evidence for a whole interval.
    expect(h.marker().lastHeldEmitMs).toBe(T0 - REFRESH_MS);
    recordTriageSweep("CAT", { considered: 2, heldDelegateUnreadable: 2 }, h.deps);
    expect(h.events).toHaveLength(2);
  });

  test("a hydrated refresh stamp survives restart without an immediate re-emit", () => {
    // Mid-outage restart: the marker on disk carries a recent emit stamp, so the
    // first post-restart sweep must stay quiet rather than restarting the clock.
    const h = harness({ consecutiveHeld: 6, alerting: true, lastHeldEmitMs: T0 - 60_000 });
    recordTriageSweep("CAT", { considered: 2, heldDelegateUnreadable: 2 }, h.deps);
    expect(h.events).toHaveLength(0);
    h.advance(REFRESH_MS);
    recordTriageSweep("CAT", { considered: 2, heldDelegateUnreadable: 2 }, h.deps);
    expect(h.events).toHaveLength(1);
  });

  test("recovery clears the refresh stamp so the next outage emits on its own edge", () => {
    const h = harness({ consecutiveHeld: 4, alerting: true, lastHeldEmitMs: T0 });
    recordTriageSweep("CAT", { considered: 2, heldDelegateUnreadable: 0 }, h.deps);
    expect(h.marker()).toEqual({ consecutiveHeld: 0, alerting: false, lastHeldEmitMs: null });
    for (let i = 0; i < 3; i++) recordTriageSweep("CAT", { considered: 2, heldDelegateUnreadable: 2 }, h.deps);
    expect(h.events.map((e) => e.action)).toEqual([TRIAGE_RECOVERED_ACTION, TRIAGE_HELD_ACTION]);
  });

  test("event builder mirrors counts onto attributes", () => {
    const held = JSON.parse(buildTriageSweepHealthEvent({ team: "CAT", action: TRIAGE_HELD_ACTION, consecutiveHeld: 3, considered: 4, heldDelegateUnreadable: 4 }));
    expect(held.attributes["event.name"]).toBe("monitor.triage.held.CAT");
    expect(held.severityText).toBe("WARN");
    expect(held.attributes["triage.consecutive_held"]).toBe(3);
    expect(held.attributes["triage.considered"]).toBe(4);
    expect(held.attributes["triage.held_delegate_unreadable"]).toBe(4);
    const recovered = JSON.parse(buildTriageSweepHealthEvent({ team: "CAT", action: TRIAGE_RECOVERED_ACTION }));
    expect(recovered.severityText).toBe("INFO");
  });

  test("marker write failures never escape", () => {
    const warn = mock(() => {});
    expect(() => recordTriageSweep("CAT", { considered: 1, heldDelegateUnreadable: 1 }, {
      threshold: 3,
      readMarker: () => null,
      writeMarker: () => { throw new Error("disk full"); },
      appendEvent: mock(() => true),
    })).not.toThrow();
    expect(warn).toBeDefined();
  });
});
