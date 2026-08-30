# PhotosIndex Verified Move Design

## Outcome

PhotosIndex treats moving a selected Apple Photos asset to iCloud Drive as a verified two-phase operation: copy the original, prove the destination is byte-identical and uploaded, then delete that exact source asset through public PhotoKit. The bundled agent workflow uses move by default while the existing `export` command remains an explicit copy-only option.

Each batch is scoped to explicit calendar dates and starts with a read-only
inventory. Fine groups remain the default; an explicit whole-date media request
may instead use deterministic photo and video groups. Assets judged personal,
ambiguous, privacy-sensitive, or unsupported remain in Photos.

## Product Semantics

`move` is not a filesystem rename because Apple Photos and iCloud Drive are separate stores. One move has these ordered phases:

1. Validate a complete `ModelDecision` for the current index run and group.
2. Materialize only `includedAssetIDs` through PhotoKit.
3. Copy them beneath the exact iCloud Drive `Naver Clip` root.
4. Re-read every destination file and verify its byte count and SHA-256 against the staged original.
5. Wait until each destination reports `isUbiquitous == true`, `isUploaded == true`, `isUploading == false`, and no upload error.
6. Persist an owner-only recovery journal containing the exact deletion targets in the app's Application Support directory.
7. Delete only the exact included PhotoKit assets with `PHAssetChangeRequest.deleteAssets` inside `PHPhotoLibrary.performChanges`.
8. Confirm those source identifiers are no longer returned by the ordinary PhotoKit fetch, write `move-receipt.json`, and remove the recovery journal.

Any failure before phase 7 leaves Photos untouched. A failure after deletion starts is safely retryable with the exact same plan and digest: the journal preserves app-only PhotoKit identifiers, deletion reconciles already-absent targets, and the receipt can be completed without a fresh index run. The journal is never exposed through the CLI or written to iCloud. Photos deletion remains recoverable through Recently Deleted; PhotosIndex never empties it.

## Evidence Coverage

The 12-sample cap remains per evidence page. A new `--page` and `--page-size` contract pages the ordered asset list, not generated frames. Page size is limited to 12 assets, and the generator requests one Photos-managed preview per asset, including a poster preview for video. This avoids downloading every full original merely to classify it. The response records page number, total pages, covered IDs, and remaining IDs. A complete decision may combine as many evidence pages as the group requires. Copy-only export and destructive move have no selected-asset ceiling because both require an explicit complete decision and a digest-bound plan. An ambiguous video poster is excluded rather than treated as whole-video proof unless the operator explicitly requested the complete date-wide video group without semantic classification. `media-kind` groups may be used for export or verified move after every evidence page is inspected.

An agent must inspect every page before claiming a whole group was reviewed. The final `ModelDecision` still partitions the complete original group. An included asset must have a direct sample reference; metadata or another asset's sample is insufficient.

## Command Contract

```text
photosindex groups inspect <group> --index-run <run> --page 1 --page-size 12 --output <dir>

photosindex move plan \
  --decision <decision.json> \
  --to <exact-iCloud-Naver-Clip-root> \
  --output <move-plan.json>

photosindex move apply \
  --plan <move-plan.json> \
  --digest <app-issued-sha256>
```

`move plan` is read-only. `move apply` is the only destructive command. Its plan is domain-separated from an export plan so a copy-only digest cannot authorize deletion. The plan must be issued by the running app session and match the current index run, group, ordered group IDs, selected IDs, destination, and staging root.

## Models and Boundaries

- `PhotosIndexCore` owns Codable `MovePlan`, `MovePlanEnvelope`, `MoveReceipt`, and digest integrity.
- `PhotosIndexEvidence` owns deterministic page selection and bounded packet generation.
- `PhotosIndexExport` owns export reuse, destination hash verification, iCloud upload verification, and move orchestration behind protocols.
- `PhotosIndexPhotos` owns the production PhotoKit deleter. Local identifiers never leave the app process.
- `PhotosIndexApp` owns issued move digests and binds the current in-memory index to plan/apply.
- `PhotosIndexCLI` owns parsing and file transport only; it remains free of PhotoKit and app-only frameworks.

## Safety Invariants

- `receipt asset IDs == move plan included IDs == deletion request public IDs`.
- Destination file count, bytes, and hashes must match the receipt immediately before deletion.
- Every destination must be uploaded and current in iCloud; local presence alone is insufficient.
- Excluded IDs are never passed to the deleter.
- Missing source assets, mismatched run/group, tampered digest, symlink, collision, upload timeout, or hash mismatch aborts deletion.
- The deletion result records each public ID; no PhotoKit local identifier, precise GPS, or Photos library path is serialized.
- The recovery journal is the sole exception for PhotoKit local identifiers: it is app-private, owner-only (`0700` directory and `0600` file), digest-bound, and removed after the move receipt is durable.
- A zero-selection group creates a classification audit record but no move plan.
- Existing verified destination files are reused only when byte-identical.

## Retry and Recovery

- Copy failure or bounded PhotoKit original-download timeout: no deletion;
  retry stages or reuses verified files.
- Upload timeout: no deletion; keep manifest/receipt and retry after iCloud catches up.
- User rejects the macOS delete confirmation: return `source-delete-cancelled`; destination remains a safe copy.
- App exit or receipt-write failure after deletion begins: retry the exact same plan and digest before re-indexing; the private journal reconciles already-absent targets and completes the receipt.
- A transport failure after request transmission is not automatically retried by
  the CLI. Reconcile the destination or recovery receipt first, then retry only
  the exact same plan and digest.
- A missing, malformed, permission-weakened, symlinked, or plan-mismatched recovery journal aborts recovery rather than guessing deletion targets.
- Verification after success: read `move-receipt.json`, recheck destination hashes, and re-sync the date to prove moved IDs are absent and excluded IDs remain. A completed move is not applied again.

## Batch Execution

Process one date at a time so the app's session-memory index remains
authoritative. For each date: sync, list the selected grouping level, inspect
every evidence page, write classification records, move only confirmed assets,
verify receipts, then re-sync to prove only moved public IDs disappeared. Fine
groups are the default. `media-kind` is allowed for an explicitly requested
whole-date photo/video export or verified move and does not replace per-asset
semantic evidence when the request selects a semantic category.
An existing compatible export may be reused only after its hashes and iCloud
upload state are revalidated.

## Verification

Automated tests cover evidence pagination, digest domain separation, deletion gating, excluded-ID preservation, upload timeout, destination tampering, idempotent retry, router/CLI round trips, and a fake deleter. Release verification includes all Swift tests, app bundle signing, skill validation, workflow dry-run, installed CLI/socket status, and an operator-approved read-only inventory before any destructive apply.
