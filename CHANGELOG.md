# Changelog

All notable changes to this project are documented in this file.

## [1.0.0] - 2026-07-30

### Added

- Privacy-first export of cycling workout routes and heart-rate samples from
  HealthKit to GPX 1.1.
- Batch export for selected workouts and workouts newer than the last
  successful export.
- iCloud Drive export with a local documents-directory fallback.
- GitHub-hosted macOS Debug/Release builds, full simulator tests, and unsigned
  Release-archive metadata validation.
- A fail-closed source-release contract tying annotated tags to the Xcode
  marketing version, changelog, synchronized `main` commit, and completed
  physical-device evidence.
- Deterministic source-only release assets with a published SHA-256 checksum.

### Security

- GPX XML values and attributes are escaped before serialization.
- Releases remain source-only until Apple signing and distribution are
  explicitly configured and validated.
