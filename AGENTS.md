# Repository guide

## Scope

This repository contains an Apple-platform app that reads cycling workouts,
routes, and heart-rate samples from HealthKit and exports GPX files locally.
Health data must remain user-controlled: the app may write to its configured
iCloud container or local documents directory, but must not transmit data to the
developer or another third party. Do not add app-initiated network calls or
analytics without an explicit, reviewed product decision.

## Validation

Run the release-contract tests on any platform:

```bash
./scripts/test-release-preflight.sh
./scripts/release-preflight.sh --candidate
```

Run the app build and unit tests on macOS with Xcode 26.2:

```bash
DEVELOPER_DIR=/Applications/Xcode_26.2.app/Contents/Developer \
  ./scripts/ci-test.sh
```

The CI build intentionally disables code signing. It proves that the source
builds and the unit tests pass; it does not produce an installable iOS binary or
exercise HealthKit/iCloud on a real device.

## Release contract

- The Xcode `MARKETING_VERSION`, annotated tag, and dated `CHANGELOG.md` entry
  must agree. Xcode version `1.0` maps to semantic release tag `v1.0.0`.
- A release tag must point at the exact synchronized `origin/main` commit.
- Tag validation must remain blocked until the versioned manual evidence file is
  complete and marked `READY`.
- GitHub releases are source-only until the signing and distribution checklist
  in `DISTRIBUTION.md` is completed.
- Never commit Apple signing certificates, provisioning profiles, App Store
  Connect keys, or their passwords.
- Never attach an unsigned, ad-hoc-signed, or unvalidated `.ipa` to a release.
