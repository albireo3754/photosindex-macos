# PhotosIndex

PhotosIndex is a local macOS toolkit that makes Apple Photos usable by external
agents without putting an AI model inside the app.

The SwiftUI app owns Photos permission, PhotoKit access, indexing, evidence
generation, and export. The `photosindex` CLI talks to that running app through a
private Unix domain socket, so scripts and agents can request bounded metadata
and evidence without reading the Photos library database directly.

## What It Does

- Uses public Apple frameworks only: PhotoKit for assets and Vision for OCR,
  face detection, and text redaction support.
- Keeps app and CLI boundaries explicit: the app owns PhotoKit and the CLI sends
  versioned requests over an owner-only Unix domain socket.
- Builds deterministic capture groups at three levels:
  - `coarse`: larger visit/session grouping.
  - `fine`: smaller candidate event grouping; nearby captures can remain together
    for the `coarse` time window, while missing location uses the shorter `fine`
    time window.
  - `media-kind`: at most one date-wide photo group and one date-wide video
    group. This is a transport grouping, not proof that every photo is a receipt
    or that every asset belongs to the same event.
- Generates bounded evidence pages for one group: up to 12 JPEG previews per
  page, OCR text, privacy flags, and redacted email/phone/long numeric
  identifiers, with explicit paging until every asset is covered.
- Expects semantic classification outside the app as a `ModelDecision`.
- Requires a complete include/exclude partition before export or move.
- Moves verified candidates by default for organization workflows: originals
  are staged, hashed, copied into iCloud, verified as uploaded, hashed again,
  and only then are the exact selected Photos assets sent to Recently Deleted.
- Retains `export` as an explicit copy-only operation.

PhotosIndex never edits assets, empties Recently Deleted, queries
`Photos.sqlite`, or touches Photos library bundle paths. Deletion is available
only through a digest-bound `move apply` issued by the running app after byte,
SHA-256, and iCloud upload verification. PhotoKit local identifiers and exact
GPS coordinates remain app-internal and are not exposed through the CLI.

## Architecture

```text
PhotosIndex.app
  SwiftUI MVVM shell
  PhotoKit authorization and date indexing
  deterministic grouping
  Vision evidence generation
  decision validation, verified move, and copy-only export
        ^
        | private owner-only Unix domain socket
        v
photosindex CLI
  status / authorize / sync
  groups list / show / inspect
  decisions validate
  export plan / apply
```

The socket defaults to `/tmp/photosindex-<uid>.sock`. The command host rejects
non-owner peers, removes only owner-owned stale sockets, and creates the socket
with restrictive permissions.

## Repository Structure

```text
AppBundle/       macOS bundle metadata and Photos entitlement
Sources/         SwiftPM modules for app, CLI, socket, PhotoKit, evidence, export
Tests/           unit, contract, recovery, and real Unix-socket tests
Examples/        synthetic decision templates; never user media
docs/            verified-move and local-signing design notes
scripts/         build, signing, install, and signing regression helpers
workflows/       bounded agent development workflow and its test
CLAUDE.md        canonical repository guidance for coding agents
AGENTS.md        symlink to CLAUDE.md
```

## Privacy And Generated Data

This repository contains source code and synthetic fixtures only. It does not
contain a Photos library snapshot, generated evidence, export receipts, or user
media. Runtime evidence can contain JPEG previews, capture timestamps, OCR,
public asset IDs, and filenames; export manifests and receipts contain hashes
and destination paths. Keep those outputs outside the repository or under the
ignored `.photosindex/` directory.

An interrupted verified move may temporarily store PhotoKit local identifiers
in an owner-only recovery journal under Application Support. The app removes
that journal after `move-receipt.json` is written successfully.

## Requirements

- macOS 14 or later.
- Xcode or Command Line Tools with Swift 6.
- An `Apple Development` signing identity for local app builds. Xcode can
  create one under **Settings > Accounts > Manage Certificates**.
- Apple Photos permission granted to `PhotosIndex.app`.
- iCloud Drive if you want to export into an iCloud folder.

Developer ID signing and notarization are not configured. Local builds use an
`Apple Development` identity so the app keeps one stable macOS code identity
across rebuilds. The build discovers the first matching identity, or you can
select one explicitly without committing it to the repository:

```bash
PHOTOSINDEX_DEVELOPMENT_IDENTITY="Apple Development: ..." make app
```

The build fails rather than silently falling back to ad-hoc signing when no
development identity exists. Disposable CI jobs can explicitly request an
ad-hoc artifact because they do not reuse local TCC grants:

```bash
PHOTOSINDEX_SIGNING_MODE=adhoc make app
```

## Build And Test

```bash
make test
make app
```

`make app` builds both products and creates:

```text
.build/PhotosIndex.app
.build/<platform>/release/photosindex
```

Install locally:

```bash
make install
```

The install script copies the CLI to `~/.local/bin/photosindex` and the app to
`~/Applications/PhotosIndex.app`.

## Human App Workflow

Open `PhotosIndex.app`, grant Photos access when prompted, choose a date using
the **Calendar date (Asia/Seoul)** picker, and select **Browse**. Browse the
result with fine, coarse, or media-kind grouping, then select an ordinal group
to see actual photo and video thumbnails alongside time and media details. Open
a photo for a larger preview or a video for native play, pause, and seek controls.
Limited Photos access indexes only the items selected in macOS privacy settings.

Media is loaded through PhotoKit, including iCloud downloads when needed. A
loading message and Retry action cover unavailable media; closing the viewer or
changing the group/date stops playback and discards pending results. Viewing
does not export files or expose Photos library paths or private identifiers.

The human UI is read-only. Evidence generation, classification,
decision validation, export, and verified move remain CLI/agent-only workflows;
the app browser exposes no export, move, or delete controls.

## CLI Quick Start

Show app, protocol, and Photos permission status:

```bash
photosindex status --format json
```

Request Photos permission through the app:

```bash
photosindex authorize --format json
```

Index one local calendar date:

```bash
photosindex sync --date 2026-01-15 --wait --format json
```

List deterministic groups from the current in-app index:

```bash
photosindex groups list --date 2026-01-15 --level fine --format json
photosindex groups list --date 2026-01-15 --level coarse --format json
photosindex groups list --date 2026-01-15 --level media-kind --format json
```

Show bounded metadata for one group:

```bash
photosindex groups show <group-id> --index-run <index-run-id> --format json
```

Materialize bounded JPEG/OCR evidence for one group:

```bash
photosindex groups inspect <group-id> \
  --index-run <index-run-id> \
  --output /tmp/photosindex-evidence/<group-id> \
  --page 1 \
  --page-size 12 \
  --samples 12 \
  --format json
```

Increment `--page` and use a fresh output directory until
`remainingAssetIDs` is empty. The 12-sample limit applies per evidence page,
not to the whole group.

Each page requests one Photos-managed preview per asset, including a poster
preview for video. This keeps classification independent from downloading every
full original. Treat an ambiguous video poster as insufficient evidence and
exclude that asset; original materialization happens only after selection.

Validate an external model decision:

```bash
photosindex decisions validate --file <decision.json> --format json
```

Start from the synthetic template in
[`Examples/model-decision.example.json`](Examples/model-decision.example.json),
then replace every run, group, asset, and evidence ID with values from the
current bounded evidence packet. Never commit a decision created from a real
Photos library.

Create and apply the default verified move plan:

```bash
photosindex move plan \
  --decision <decision.json> \
  --to "${HOME}/Library/Mobile Documents/com~apple~CloudDocs/Naver Clip" \
  --layout dated-group \
  --output <move-plan.json> \
  --format json

photosindex move apply \
  --plan <move-plan.json> \
  --digest <sha256-from-move-plan> \
  --format json
```

`move apply` writes a digest-named move plan before source deletion and writes
`move-receipt.json` only after PhotoKit confirms that exactly the selected
public asset IDs are absent. Any upload or hash failure stops before deletion.
Large iCloud originals may keep this command running for a long time: each
PhotoKit original request is bounded at 15 minutes and the move CLI connection
is allowed to remain open for up to four hours.
The CLI may launch the app after a pre-request connection failure, but it never
automatically resends a request after the socket connection was established.
After an interrupted response, inspect the destination state and retry only the
same plan and digest.
Immediately before deletion, the app also writes an owner-only recovery journal
under its Application Support directory. If the app exits after deletion but
before the receipt is written, retry the exact same plan and digest; the app
reconciles already-absent sources and completes the receipt without requiring a
new index run. The journal is removed after success and is never returned by the
CLI or stored in iCloud. Deleted sources remain recoverable in Photos Recently
Deleted.

Create a digest-bound copy-only export plan when Photos should retain the
source:

```bash
photosindex export plan \
  --decision <decision.json> \
  --to "${HOME}/Library/Mobile Documents/com~apple~CloudDocs/Naver Clip" \
  --layout dated-group \
  --output <export-plan.json> \
  --format json
```

Apply exactly that app-issued plan:

```bash
photosindex export apply \
  --plan <export-plan.json> \
  --digest <sha256-from-export-plan> \
  --format json
```

`export apply` requires the current in-memory index to match the plan run and
group, the plan digest to match the canonical plan JSON, and the digest to have
been issued by the running app session. Date-wide exports may run for a long
time, so the CLI connection remains open for up to four hours. A transport
failure after request transmission is not automatically retried; inspect the
destination and retry only the same plan and digest after reconciling any
existing manifest and receipt.

## ModelDecision Contract

PhotosIndex does not decide whether a group contains a restaurant, dish, person,
or publishable media. An external model or agent must inspect the bounded
evidence and write a `ModelDecision` JSON.

The decision must:

- Match the current `indexRunID` and `groupID`.
- Use confidence `>= 0.80`.
- Leave `unknowns` empty for export.
- Put every group asset ID in exactly one of `includedAssetIDs` or
  `excludedAssetIDs`.
- Inspect every asset through 12-asset evidence pages; one verified decision may
  combine as many pages as the group requires.
- Reference evidence that supports the selected assets.

Assets that are personal, ambiguous, privacy-sensitive, or unsupported by the
bounded evidence should be excluded.

For a whole-date media operation, request `media-kind` groups. The video group can
include every video when the operator explicitly wants the complete date-wide
video set. Inspect the photo group page by page and include only photos whose
own evidence supports the requested class, such as receipts; exclude every
other photo. The 12-asset evidence page size remains bounded, but the final
decision, export, and move have no asset-count ceiling. A `media-kind` decision
may be used for copy-only export or verified move after every evidence page is
inspected and the complete include/exclude partition is validated.

## Move And Export Output

The supported export layout is `dated-group`:

```text
<iCloud Naver Clip root>/
  YYYY-MM-DD_<safe-label>/
    originals/
      <copied original files>
    manifest.json
    receipt.json
    move-plan-<sha256>.json  # move only
    move-receipt.json        # move only, written after source deletion
```

`manifest.json` records the canonical export plan. `receipt.json` records each
copied file with relative path, byte count, SHA-256 digest, media kind, and
whether an identical existing file was reused.

## Agent Skill And Workflow

The repository embeds a Codex skill for using the toolkit safely:

```text
.agents/skills/use-photosindex/SKILL.md
```

It describes the safe sequence for status, authorization, full paged evidence,
external classification, decision validation, verified move, post-move sync,
and explicit copy-only export.

The repo also includes a bounded development workflow:

```bash
node --test workflows/photosindex-development.test.mjs
```

`workflows/photosindex-development.mjs` is host-agnostic and can be loaded by a
compatible agent workflow runner.

## MVP Limitations

- The current index is session-memory state owned by the running app. Re-sync
  after restarting `PhotosIndex.app`.
- The app is not notarized and has no Developer ID distribution pipeline yet.
- The app provides an agent toolkit and evidence contract, not embedded AI.
- `--wait` is currently part of the CLI contract for sync, but indexing runs
  synchronously in this MVP.
