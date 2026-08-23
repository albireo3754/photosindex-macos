const reviewSchema = {
  type: "object",
  additionalProperties: false,
  required: ["area", "verdict", "findings", "recommendedChanges", "tests"],
  properties: {
    area: { type: "string" },
    verdict: { type: "string", enum: ["pass", "changes-required", "blocked"] },
    findings: { type: "array", items: { type: "string" } },
    recommendedChanges: { type: "array", items: { type: "string" } },
    tests: { type: "array", items: { type: "string" } },
  },
};

const implementationSchema = {
  type: "object",
  additionalProperties: false,
  required: ["summary", "changedFiles", "tests", "remainingRisks"],
  properties: {
    summary: { type: "string" },
    changedFiles: { type: "array", items: { type: "string" } },
    tests: { type: "array", items: { type: "string" } },
    remainingRisks: { type: "array", items: { type: "string" } },
  },
};

const verificationSchema = {
  type: "object",
  additionalProperties: false,
  required: ["verdict", "checks", "failures", "evidence"],
  properties: {
    verdict: { type: "string", enum: ["pass", "fail", "blocked"] },
    checks: { type: "array", items: { type: "string" } },
    failures: { type: "array", items: { type: "string" } },
    evidence: { type: "array", items: { type: "string" } },
  },
};

export const meta = {
  name: "photosindex-development",
  description: "Review, implement, and verify the PhotosIndex macOS MVP with bounded fan-out.",
  phases: [
    { title: "Read-only review", detail: "Fan out architecture, evidence, and safety checks." },
    { title: "Implementation", detail: "Apply only substantiated changes in one edit lane." },
    { title: "Verification", detail: "Hand the result to an independent read-only verifier." },
  ],
};

export default async function run({ args, cwd, phase, log, agent, parallel }) {
  const scope = args[0] || "photosindex-macos";

  await phase("Read-only review");
  const reviews = await parallel(
    [
      () => agent(
        `In ${cwd}, review ${scope} without editing files. Check the SwiftPM target graph, minimal SwiftUI MVVM boundaries, CLI-to-private-Unix-socket round trip, versioned command contract, deterministic coarse/fine grouping, stale indexRunID/groupID handling, and tests. Cite concrete repository paths. Do not request Photos permission or inspect user media.`,
        { label: "architecture-review", schema: reviewSchema }
      ),
      () => agent(
        `In ${cwd}, review ${scope} evidence and decision behavior without editing files. Check groups show/inspect, deterministic sampling capped at 12 combined photo/video samples, OCR/privacy redaction, absence of exact GPS/PHAsset local IDs/library paths, external ModelDecision creation, and a complete disjoint include/exclude partition. A capture group must not be treated as semantic proof. Cite concrete paths and tests. Do not inspect live Photos data.`,
        { label: "evidence-review", schema: reviewSchema }
      ),
      () => agent(
        `In ${cwd}, review ${scope} safety without editing files. Check public PhotoKit-only access, UDS ownership/permissions/peer validation, no direct Photos database or Photos library bundle mutation, digest-bound copy-only export and verified move plan/apply, destination containment, symlink/path traversal/collision handling, and manifest/receipt count/bytes/SHA-256 verification. For verified move, require every iCloud original to be uploaded/current and rehashed before exact selected-source deletion through public PhotoKit, followed by a move receipt. Also review stable Apple Development signing with explicit ad-hoc CI opt-in. Cite concrete paths and tests. Do not run live exports or moves.`,
        { label: "safety-review", schema: reviewSchema }
      ),
    ],
    { concurrency: 3 }
  );
  await log("read-only reviews complete", { count: reviews.length });

  await phase("Implementation");
  const implementation = await agent(
    `Work in ${cwd} on ${scope}. You are the single implementation lane, but other work may already exist in the tree: preserve it and never revert unrelated edits. Inspect the current code and the three review results below. Implement only substantiated MVP fixes, using tests first and keeping SwiftUI MVVM, the CLI/private UDS boundary, public PhotoKit, bounded evidence, explicit copy-only export, and receipt-gated verified move intact. Do not commit, request TCC, access live Photos, write to iCloud, or delete user media. Run focused tests and report exact changed files and commands.\n\nReviews:\n${JSON.stringify(reviews, null, 2)}`,
    { label: "implementation", schema: implementationSchema }
  );

  await phase("Verification");
  const verification = await agent(
    `Independently verify ${scope} in ${cwd} after the implementation handoff below. Do not edit files. Inspect the diff and run the relevant unit tests, Swift build/app bundle checks, skill quick validation, and static safety scans that do not require TCC or user media. Confirm the CLI/UDS contract, max-12 evidence invariant, complete decision partition validation, copy-only export gates, verified move upload/rehash/exact-deletion gates, move receipts, and local development signing policy. Report only observed evidence; mark anything requiring live Photos or iCloud as not exercised rather than guessing. Do not invoke this workflow recursively.\n\nImplementation handoff:\n${JSON.stringify(implementation, null, 2)}`,
    { label: "verifier-handoff", schema: verificationSchema }
  );

  return { scope, reviews, implementation, verification };
}
