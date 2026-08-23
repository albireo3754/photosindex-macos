---
name: use-photosindex
description: Use when Apple Photos must be discovered, date-grouped, fully inspected, classified, copy-exported, or safely moved through the PhotosIndex macOS app and CLI.
---

# Use PhotosIndex

PhotosIndex supplies bounded evidence; the calling agent decides semantics. A capture group is a time/location cohort, never proof of a place, dish, or personal context. Keep discovery read-only. When the user asks to organize or archive verified candidates, use the receipt-gated `move` path by default; use `export` only when the user explicitly wants to retain the Photos source.

## Inspect every asset

1. Run `photosindex status --format json`. If Photos access is not authorized, run `photosindex authorize --format json` and let the user resolve the macOS prompt. Never bypass TCC or query `Photos.sqlite`.
2. Run `photosindex sync --date YYYY-MM-DD --wait --format json`. Record its `indexRunID`.
3. Run `photosindex groups list --date YYYY-MM-DD --level fine --format json`, then `photosindex groups show <groupID> --index-run <indexRunID> --format json` for every group in scope. Metadata narrows context but does not prove an event.
4. Inspect every asset, not only the first sample page. Run `photosindex groups inspect <groupID> --index-run <indexRunID> --page 1 --page-size 12 --samples 12 --output <temporary-directory>/page-1 --format json`, incrementing `--page` and using a new output directory until `remainingAssetIDs` is empty. Each video sample is a Photos-managed poster preview, not proof of every scene. Reject a packet with more than 12 samples, a mismatched run/group/page, or missing coverage; exclude a video whose poster is ambiguous.
5. Classify outside PhotosIndex. Include an asset only when its own sample directly supports the requested Naver Clip use. Put every personal, ambiguous, privacy-sensitive, unrelated, or unobserved asset in `excludedAssetIDs`, with a local audit reason of `personal`, `unknown`, `privacy`, `unrelated`, or `unobserved`.

Write one complete `ModelDecision` whose included and excluded IDs are disjoint and together equal every asset ID in the group:

```json
{"schemaVersion":1,"indexRunID":"run_...","groupID":"segment_...","label":"음식점-상호미확인","confidence":0.9,"includedAssetIDs":[],"excludedAssetIDs":[],"evidenceReferences":["page-1/sample_..."],"unknowns":[]}
```

Every included ID needs a directly linked sample. Confidence cannot exceed the weakest included classification. `unknowns` records unresolved selected-result claims, not exclusion reasons. Use a venue name only when OCR or visible evidence supports it; otherwise use a factual generic label such as `음식점-상호미확인`. Multiple 12-asset evidence pages may support one decision, with at most 120 selected assets per operation.

## Verified move gate (default organization action)

Validate and plan without mutation:

```bash
photosindex decisions validate --file <decision.json> --format json
photosindex move plan --decision <decision.json> \
  --to "${HOME}/Library/Mobile Documents/com~apple~CloudDocs/Naver Clip" \
  --layout dated-group --output <move-plan.json> --format json
```

Inspect the returned plan before apply. Its run, group, complete partition, included IDs, label, and destination must match the decision, and the destination must be exactly `YYYY-MM-DD_<verified-label>` below the iCloud `Naver Clip` root. Apply only with the exact app-issued digest:

```bash
photosindex move apply --plan <move-plan.json> --digest <returned-sha256> --format json
```

`move apply` is a two-phase, recoverable Photos move: it materializes originals, verifies destination byte counts and SHA-256, waits for iCloud to report every file current and uploaded, verifies hashes again, records an immutable digest-named move plan plus an app-private owner-only recovery journal, then deletes exactly the included assets through PhotoKit. The deletion goes to Photos **Recently Deleted**. Never empty Recently Deleted. Any error before deletion leaves Photos untouched; stop on an upload timeout, hash mismatch, incomplete receipt, or deletion-count mismatch. If the app exits or receipt writing fails after deletion begins, do not re-sync or create a replacement plan first: retry the exact same plan and digest so the journal can reconcile already-absent sources and finish `move-receipt.json`.

A compatible older copy-only export may be adopted only when its group, full include/exclude partition, label, destination, receipt entries, byte counts, and hashes match. Never overwrite a conflicting destination.

After each move:

1. Require `manifest.json`, `receipt.json`, a digest-named `move-plan-*.json`, and `move-receipt.json`.
2. Recompute every destination SHA-256 and byte count and compare them with the receipt.
3. Re-sync the capture date. Every `deletedAssetID` must be absent and every excluded ID must remain.
4. Report the destination, file/byte totals, deleted public IDs, excluded-reason totals, warnings, and the fact that Photos recovery remains available.

## Explicit copy-only mode

Use `photosindex export plan` and `photosindex export apply` only when the user explicitly wants a duplicate while retaining Photos originals. Copy mode writes `manifest.json` and `receipt.json` but never deletes. Do not use a broader destination, whole-library export, direct Photos database/library paths, PhotoKit local identifiers, or exact GPS. If a required command is unavailable, report it as the blocker instead of inventing a workaround.
