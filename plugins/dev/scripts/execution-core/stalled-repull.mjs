// stalled-repull.mjs — CAT-223 machine-owned stalled-worker recycling.
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const TERMINAL = new Set(["stalled", "failed", "aborted"]);
export function isStalledRepullable({ signals, class: cls, bgProtected, ageMs, attempts, opts }) {
  const statuses = Object.values(signals ?? {});
  if (statuses.length === 0) return { ok: false, reason: "empty-signals" };
  if (statuses.some((s) => !TERMINAL.has(s))) return { ok: false, reason: "non-terminal-signal" };
  if (cls !== "machine-owned") return { ok: false, reason: "class-not-machine-owned" };
  if (bgProtected) return { ok: false, reason: "bg-protected" };
  if (!Number.isFinite(ageMs) || ageMs < opts.graceMs) return { ok: false, reason: "inside-grace" };
  if ((attempts ?? 0) >= opts.maxRepullAttempts) return { ok: false, reason: "attempt-cap" };
  return { ok: true, reason: "eligible" };
}
export function detachWorkerDir(orchDir, ticket, { now = Date.now() } = {}) {
  const source = join(orchDir, "workers", ticket);
  const retainedRoot = join(orchDir, ".repulled");
  mkdirSync(retainedRoot, { recursive: true });
  const path = join(retainedRoot, `${ticket}-${now}`);
  renameSync(source, path);
  return { ok: true, path };
}
function attemptPath(orchDir, ticket) {
  return join(orchDir, ".stalled-repull", `${ticket}.json`);
}
export function readRepullAttempts(orchDir, ticket) {
  try {
    return JSON.parse(readFileSync(attemptPath(orchDir, ticket), "utf8"));
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
    return { attempts: 0, lastRepullAt: null };
  }
}
export function recordRepullAttempt(orchDir, ticket, { now = Date.now() } = {}) {
  const dir = join(orchDir, ".stalled-repull");
  mkdirSync(dir, { recursive: true });
  const current = readRepullAttempts(orchDir, ticket);
  const value = { attempts: (current.attempts ?? 0) + 1, lastRepullAt: now };
  const path = attemptPath(orchDir, ticket);
  const tmp = `${path}.tmp.${process.pid}`;
  writeFileSync(tmp, `${JSON.stringify(value)}\n`);
  renameSync(tmp, path);
  return value;
}
