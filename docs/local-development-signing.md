# Local Development Signing Design

## Context

`PhotosIndex.app` already has the stable bundle identifier
`dev.pray.PhotosIndex`, but `scripts/build-app.sh` signs it ad hoc. An ad-hoc
signature uses the build's code-directory hash as its designated requirement,
so rebuilding changes the identity macOS TCC uses for Photos permission.

## Decision

- Local builds use an `Apple Development` identity.
- `PHOTOSINDEX_DEVELOPMENT_IDENTITY` may select the identity explicitly;
  otherwise the first valid `Apple Development:` identity is discovered from
  the login keychain.
- Missing development identity is an actionable build failure. The build never
  silently falls back to ad-hoc signing.
- CI may opt into ad-hoc signing explicitly with
  `PHOTOSINDEX_SIGNING_MODE=adhoc` because CI does not reuse TCC grants.
- Developer ID signing, timestamps, notarization, and release distribution are
  outside this local-development change.
- Building an artifact never automatically replaces the currently installed
  app; installation remains an explicit step.

## Verification

A shell regression test injects fake `security` and `codesign` commands to
prove development identity discovery, explicit identity selection, missing
identity failure, explicit ad-hoc mode, and invalid-mode rejection. `make test`
runs that test before the Swift suite.
