import { describe, expect, test } from "bun:test";
import { readReplicaState, resolveIntervalMs, sampleReplicaOnce, startReplicaSampleTimer } from "./replica-sample-timer.mjs";

const fakeClock = () => { const timers = []; return { timers, setInterval: (fn, ms) => { timers.push({ fn, ms }); return { unref() {} }; }, clearInterval: () => timers.splice(0), now: () => 1_786_000_000_000 }; };
const capture = () => { const writes = new Map(); return { writes, ops: { writeFileSync: (p, d) => writes.set(p, d), renameSync: (a, b) => writes.set(b, writes.get(a)) } }; };

describe("replica sampler", () => {
  test("atomically publishes populated and absent snapshots", () => {
    for (const probed of [{ dbPresent: true, issueRows: 5 }, { dbPresent: false }]) {
      const { writes, ops } = capture();
      expect(sampleReplicaOnce({ orchDir: "/tmp/orch", clock: fakeClock(), fileOps: ops, mkdir: () => {}, probe: () => probed, registeredTeams: () => ["CAT"] })).toBe(true);
      expect(JSON.parse(writes.get("/tmp/orch/replica-state.json"))).toMatchObject({ ...probed, registeredTeams: ["CAT"] });
    }
  });
  test("probe failure is contained and registry failure degrades coverage only", () => {
    expect(sampleReplicaOnce({ orchDir: "/tmp/o", probe: () => { throw new Error("locked"); }, log: { warn() {} } })).toBe(false);
    const { writes, ops } = capture();
    expect(sampleReplicaOnce({ orchDir: "/tmp/orch", clock: fakeClock(), fileOps: ops, mkdir: () => {}, probe: () => ({ dbPresent: true }), registeredTeams: () => { throw new Error("registry"); }, log: { warn() {} } })).toBe(true);
    expect(JSON.parse(writes.get("/tmp/orch/replica-state.json")).registeredTeams).toEqual([]);
  });
  test("interval guard rejects spawn-storm values", () => {
    for (const bad of ["", "abc", 0, -1, NaN, {}]) expect(resolveIntervalMs(bad, { warn() {} })).toBe(300_000);
    expect(resolveIntervalMs(30)).toBe(30_000);
  });
  test("disabled is inert; enabled primes synchronously", () => {
    const disabled = fakeClock(); expect(startReplicaSampleTimer({ enabled: false, orchDir: "/tmp/o", clock: disabled }).primed).toBe(false); expect(disabled.timers).toHaveLength(0);
    const clock = fakeClock(); const { writes, ops } = capture();
    expect(startReplicaSampleTimer({ enabled: true, orchDir: "/tmp/orch", clock, fileOps: ops, mkdir: () => {}, probe: () => ({ dbPresent: true }), registeredTeams: () => [], primeImmediately: true }).primed).toBe(true);
    expect(writes.has("/tmp/orch/replica-state.json")).toBe(true); expect(clock.timers[0].ms).toBe(300_000);
  });
  test("missing and corrupt state reads return null", () => {
    expect(readReplicaState("/nope/nowhere")).toBeNull();
    expect(readReplicaState("/tmp/o", { readFile: () => "{oops", log: { warn() {} } })).toBeNull();
  });
});
