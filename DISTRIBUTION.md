# Distribution

## Current release boundary

GitHub releases for this repository are **source-only**. The release workflow
attaches a deterministic source archive and its SHA-256 checksum. It does not
upload or attach an `.ipa`, `.app`, `.pkg`, `.dmg`, or Xcode archive.

The first `v1.0.0` tag is intentionally blocked until
[`release/evidence/v1.0.0.md`](release/evidence/v1.0.0.md) is marked `READY`,
has no incomplete checkbox or placeholder, and that evidence change passes a
separate pull-request review. Defining the workflow is not authorization to
create the tag.

The GitHub-hosted macOS gate proves that:

- the tagged source is the exact synchronized `origin/main` commit;
- the annotated tag `v1.0.0`, Xcode marketing version `1.0`, build `2`, and
  dated changelog agree;
- Debug and Release compile for an iOS simulator with signing disabled;
- the full unit and UI test suite passes on an available iOS simulator;
- an unsigned Release archive can be created for a generic iOS device;
- archive metadata, usage descriptions, and source entitlements match the
  release contract; and
- the deterministic source archive matches its published SHA-256.

It does **not** prove that:

- the bundle identifier and iCloud container are registered to the intended
  Apple Developer account;
- HealthKit or iCloud capabilities work on a physical device;
- an archive can be signed or validated by App Store Connect;
- the app has completed TestFlight testing or App Review; or
- an installable artifact is safe to distribute.

## Before distributing an installable build

Complete and review all of the following as a separate issue and pull request:

1. Confirm Apple Developer Program membership and the intended iOS/iPadOS
   distribution channel (TestFlight/App Store or registered devices).
2. Confirm the permanent product name, bundle identifier
   (`com.minghsuy.HealthKitGPXExporter`), supported platforms, and deployment
   targets.
3. Register and verify the HealthKit capability and
   `iCloud.com.minghsuy.HealthKitGPXExporter` container in the developer portal.
4. Add a production app icon and all store metadata and privacy disclosures
   required for the selected channel.
5. Create the App Store Connect app record and configure least-privilege signing
   credentials. Store credentials only in an approved secret store.
6. Archive and validate the Release configuration with Apple signing enabled.
7. Run a physical-device smoke test using representative HealthKit cycling,
   route, and heart-rate data. Verify both iCloud and local fallback exports and
   inspect the resulting GPX in an independent consumer.
8. Distribute the validated build through TestFlight before App Review or other
   end-user distribution.
9. Retain the exact archive and dSYMs for every distributed build.

Do not attach unsigned, ad-hoc-signed, or unvalidated Apple application bundles
to GitHub releases.

## Source-release procedure

1. Complete the physical-device, Apple-account, privacy, independent GPX, and
   recovery checks in `release/evidence/v1.0.0.md`.
2. Submit that evidence in a pull request. Require exact-head CI and bot reviews
   to be green and resolve every review thread before merge.
3. Confirm the reviewed merge commit is in synchronized `origin/main` history
   and its exact main-branch CI is green.
4. Run `./scripts/release-preflight.sh --candidate` at that exact commit.
5. Create an annotated tag without moving any existing tag:

   ```bash
   git tag -a v1.0.0 <exact-main-commit> -m "v1.0.0"
   git push origin v1.0.0
   ```

6. Monitor the source-release workflow. It revalidates the tag against
   synchronized `main`, repeats the full macOS gate and unsigned archive
   inspection, and publishes only the deterministic source archive and checksum.
7. Download both assets from GitHub and run:

   ```bash
   sha256sum --check HealthKitGPXExporter-1.0.0-source.tar.gz.sha256
   ```

If the workflow fails before publishing, fix the cause through a new pull
request before creating a new patch-version tag. If it fails after creating the
GitHub release, rerun the same workflow; it safely repairs the notes and the two
expected source assets. Never delete, move, or recreate a published tag. Never
repair a release by attaching an unsigned application bundle.
