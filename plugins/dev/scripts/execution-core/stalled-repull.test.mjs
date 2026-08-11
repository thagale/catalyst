import { expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  isStalledRepullable,
  detachWorkerDir,
  recordRepullAttempt,
  readRepullAttempts,
} from "./stalled-repull.mjs";
import { readStalledRepullConfig } from "./config.mjs";

const base = {
  signals: { implement: "stalled" },
  class: "machine-owned",
  bgProtected: false,
  ageMs: 31,
  attempts: 0,
  opts: { graceMs: 30, maxRepullAttempts: 2 },
};
test("repull eligibility requires terminal machine-owned unprotected old work", () => {
  expect(isStalledRepullable(base)).toEqual({ ok: true, reason: "eligible" });
  expect(isStalledRepullable({ ...base, class: "operator-owned" }).reason).toBe(
    "class-not-machine-owned"
  );
  expect(isStalledRepullable({ ...base, signals: { implement: "running" } }).reason).toBe(
    "non-terminal-signal"
  );
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
  expect(JSON.parse(readFileSync(join(orch, ".stalled-repull", "CAT-223.json"))).lastRepullAt).toBe(
    123
  );
});

test("malformed attempt records fail closed", () => {
  const orch = mkdtempSync(join(tmpdir(), "repull-malformed-"));
  mkdirSync(join(orch, ".stalled-repull"), { recursive: true });
  writeFileSync(join(orch, ".stalled-repull", "CAT-223.json"), "not-json\n");
  expect(() => readRepullAttempts(orch, "CAT-223")).toThrow();
});

test("non-throwing malformed attempt shapes exhaust the cap", () => {
  const orch = mkdtempSync(join(tmpdir(), "repull-malformed-shape-"));
  mkdirSync(join(orch, ".stalled-repull"), { recursive: true });
  writeFileSync(join(orch, ".stalled-repull", "CAT-223.json"), "{}\n");
  expect(readRepullAttempts(orch, "CAT-223").attempts).toBe(Infinity);
});

test("detach refuses to archive an unconsumed inbox", () => {
  const orch = mkdtempSync(join(tmpdir(), "repull-inbox-"));
  const worker = join(orch, "workers", "CAT-223");
  mkdirSync(worker, { recursive: true });
  writeFileSync(join(worker, "inbox.jsonl"), '{"type":"directive"}\n');
  expect(() => detachWorkerDir(orch, "CAT-223")).toThrow("unconsumed inbox");
  expect(existsSync(worker)).toBe(true);
});

test("repull config reads the documented Layer-1 location", () => {
  const root = mkdtempSync(join(tmpdir(), "repull-config-"));
  const configPath = join(root, "config.json");
  writeFileSync(
    configPath,
    JSON.stringify({
      catalyst: {
        orchestration: {
          stalledRepull: {
            mode: "enforce",
            graceMs: 11,
            maxRepullAttempts: 3,
            repullBackoffMs: 22,
          },
        },
      },
    })
  );
  expect(readStalledRepullConfig({ CATALYST_CONFIG_FILE: configPath })).toEqual({
    mode: "enforce",
    graceMs: 11,
    maxRepullAttempts: 3,
    repullBackoffMs: 22,
  });
});

test("invalid set env mode fails safe instead of inheriting Layer-1 enforce", () => {
  const root = mkdtempSync(join(tmpdir(), "repull-config-invalid-env-"));
  const configPath = join(root, "config.json");
  writeFileSync(configPath, JSON.stringify({ catalyst: { orchestration: { stalledRepull: {
    mode: "enforce",
  } } } }));
  expect(readStalledRepullConfig({
    CATALYST_CONFIG_FILE: configPath,
    CATALYST_STALLED_REPULL: "enfore",
  }).mode).toBe("shadow");
  expect(readStalledRepullConfig({
    CATALYST_CONFIG_FILE: configPath,
    CATALYST_STALLED_REPULL: "0",
  }).mode).toBe("off");
});
