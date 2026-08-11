import { expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { isStalledRepullable, detachWorkerDir, recordRepullAttempt, readRepullAttempts } from "./stalled-repull.mjs";
import { readStalledRepullConfig } from "./config.mjs";

const base = { signals: { implement: "stalled" }, class: "machine-owned", bgProtected: false, ageMs: 31, attempts: 0, opts: { graceMs: 30, maxRepullAttempts: 2 } };
test("repull eligibility requires terminal machine-owned unprotected old work", () => {
  expect(isStalledRepullable(base)).toEqual({ ok: true, reason: "eligible" });
  expect(isStalledRepullable({ ...base, class: "operator-owned" }).reason).toBe("class-not-machine-owned");
  expect(isStalledRepullable({ ...base, signals: { implement: "running" } }).reason).toBe("non-terminal-signal");
  expect(isStalledRepullable({ ...base, bgProtected: true }).reason).toBe("bg-protected");
  expect(isStalledRepullable({ ...base, ageMs: 1 }).reason).toBe("inside-grace");
  expect(isStalledRepullable({ ...base, attempts: 2 }).reason).toBe("attempt-cap");
});

test("detach preserves contents and attempt records survive reads", () => {
  const orch = mkdtempSync(join(tmpdir(), "repull-"));
  mkdirSync(join(orch, "workers", "CAT-223"), { recursive: true });
  writeFileSync(join(orch, "workers", "CAT-223", "phase-implement.json"), "{}\n");
  const detached = detachWorkerDir(orch, "CAT-223", { now: 123 });
  expect(detached.path).toBe(join(orch, ".repulled", "CAT-223-123"));
  expect(existsSync(join(detached.path, "phase-implement.json"))).toBe(true);
  recordRepullAttempt(orch, "CAT-223", { now: 123 });
  expect(readRepullAttempts(orch, "CAT-223").attempts).toBe(1);
  expect(JSON.parse(readFileSync(join(orch, ".stalled-repull", "CAT-223.json"))).lastRepullAt).toBe(123);
});

test("repull config reads the documented Layer-1 location", () => {
  const root = mkdtempSync(join(tmpdir(), "repull-config-"));
  const configPath = join(root, "config.json");
  writeFileSync(configPath, JSON.stringify({
    catalyst: { orchestration: { stalledRepull: {
      mode: "enforce", graceMs: 11, maxRepullAttempts: 3, repullBackoffMs: 22,
    } } },
  }));
  expect(readStalledRepullConfig({ CATALYST_CONFIG_FILE: configPath })).toEqual({
    mode: "enforce", graceMs: 11, maxRepullAttempts: 3, repullBackoffMs: 22,
  });
});
