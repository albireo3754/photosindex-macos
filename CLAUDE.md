# PhotosIndex Repository Guide

PhotosIndex is a macOS-only Swift toolkit that exposes bounded Apple Photos
metadata and evidence to external agents through a private Unix domain socket.
The SwiftUI app owns Photos permission and all PhotoKit work; the CLI is a thin
transport client and must remain free of PhotoKit.

## Read First

1. `docs/agent-publication-privacy.md` — mandatory privacy gate for public
   commits, issues, pull requests, comments, releases, and attachments.
2. `README.md` — product behavior, build commands, CLI contract, and privacy
   boundaries.
3. `docs/verified-move-design.md` — copy, upload, rehash, delete, and recovery
   invariants.
4. `docs/local-development-signing.md` — stable local signing and TCC identity.
5. `.agents/skills/use-photosindex/SKILL.md` — safe agent-facing operating
   sequence.

## Module Boundaries

- `PhotosIndexCore`: Codable contracts, grouping, canonical JSON, and digests.
- `PhotosIndexCommand`: versioned request/response protocol and owner-only Unix
  socket transport.
- `PhotosIndexPhotos`: public PhotoKit reads and exact selected-asset deletion.
- `PhotosIndexEvidence`: bounded previews, Vision OCR, privacy flags, and
  redaction.
- `PhotosIndexExport`: staging, hashes, iCloud verification, receipts, and
  interrupted-move recovery.
- `PhotosIndexApp`: SwiftUI/MVVM composition and command routing.
- `PhotosIndexCLI`: argument parsing and app transport only.

Keep these boundaries explicit. Do not move PhotoKit, Vision, or deletion logic
into the CLI.

## Safety And Privacy Invariants

- Use public PhotoKit APIs only. Never query `Photos.sqlite`, inspect a Photos
  library bundle, or use private/KVC fields.
- Never commit user media, evidence previews, OCR output, manifests, receipts,
  decisions, Photos identifiers, exact GPS, local paths, credentials, signing
  material, or workflow run logs.
- Put local runtime output under `.photosindex/` or another ignored directory.
- The CLI may expose coarse metadata and public hashed asset IDs, but never a
  PhotoKit local identifier or exact coordinate.
- Evidence is paged and capped at 12 samples per page. A group is a time/location
  cohort, not semantic proof.
- A `ModelDecision` must completely and disjointly partition the group. Include
  an asset only when its own evidence supports the classification.
- `export` is copy-only. `move` may delete only the included PhotoKit assets
  after destination byte counts, SHA-256 hashes, and iCloud uploaded/current
  state all pass. Never empty Photos Recently Deleted.
- Keep bundle identifier `dev.pray.PhotosIndex` stable. Local builds default to
  Apple Development signing; ad-hoc signing requires explicit CI opt-in.

## Development Workflow

Run before committing:

```bash
make test
swift build -c release
```

`make test` covers signing policy, the JavaScript workflow contract, and the
Swift suite. Tests must use synthetic dates, labels, identifiers, filenames,
coordinates, and byte payloads. They must not request TCC or access live Photos
or iCloud data.

When changing public contracts, update the corresponding CLI, router, Codable
models, tests, README, and embedded skill together. Prefer focused changes over
new abstractions, preserve unrelated work, and verify the exact failure or
safety invariant being changed.

## Public Repository Hygiene

- `README.md`, `Examples/`, and tests are public-facing. Keep every fixture
  visibly synthetic.
- `CLAUDE.md` is the canonical agent guide. `AGENTS.md` must remain a symlink to
  it so clients share one source of truth.
- Treat every remote target as public when its visibility is unknown. Before an
  agent creates or updates an issue, pull request, comment, review, release, or
  attachment, it must follow `docs/agent-publication-privacy.md`, show the exact
  sanitized payload to the user, and receive explicit approval. Permission to
  perform the task is not permission to disclose private context.
- Do not add machine-specific absolute paths or personal email addresses.
- Do not weaken `.gitignore` coverage for build, runtime, Xcode user data,
  signing material, environment files, or exported media.
