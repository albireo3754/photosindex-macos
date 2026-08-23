import assert from "node:assert/strict";
import test from "node:test";

import run from "./photosindex-development.mjs";

test("workflow reviews and preserves verified move plus local signing invariants", async () => {
  const prompts = new Map();
  const agent = async (prompt, options) => {
    prompts.set(options.label, prompt);
    if (options.label.endsWith("review")) {
      return {
        area: options.label,
        verdict: "pass",
        findings: [],
        recommendedChanges: [],
        tests: [],
      };
    }
    if (options.label === "implementation") {
      return { summary: "ok", changedFiles: [], tests: [], remainingRisks: [] };
    }
    return { verdict: "pass", checks: [], failures: [], evidence: [] };
  };

  await run({
    args: ["photosindex-macos"],
    cwd: "/workspace",
    phase: async () => {},
    log: async () => {},
    agent,
    parallel: async (tasks) => Promise.all(tasks.map((task) => task())),
  });

  const safety = prompts.get("safety-review");
  assert.match(safety, /verified move/);
  assert.match(safety, /uploaded\/current/);
  assert.match(safety, /Apple Development/);
  assert.doesNotMatch(safety, /no direct Photos deletion API/i);
  assert.match(prompts.get("implementation"), /receipt-gated verified move/);
  assert.match(prompts.get("verifier-handoff"), /move receipts/);
});
