# CI

All jobs run on GitHub-hosted runners. This repository is public, so no job may
run on a self-hosted runner.

## What runs

| Workflow | Trigger | Checks |
|---|---|---|
| `ci.yml` | pull request, push to `main` | Builds the `HealthKitGPXExporter` scheme for an iOS Simulator (`macos-26`, Xcode 26.6, iPhone 17, newest installed iOS runtime) and runs the unit test target `HealthKitGPXExporterTests`. |
| `testflight.yml` | push to `main`, manual dispatch | Archives a signed Release build and uploads it to TestFlight. Inactive (succeeds without uploading) until the App Store Connect secrets below exist. |
| `actionlint.yml` | pull request | Lints every workflow file with a digest-pinned actionlint container, which includes shellcheck for `run:` blocks. |

Details:

- **Unsigned.** The build passes `CODE_SIGNING_ALLOWED=NO`, and CI uses no
  certificates, profiles or secrets. As a result the HealthKit entitlement is
  not embedded, so unit tests must not depend on real HealthKit authorization.
- **Unit tests only.** `HealthKitGPXExporterUITests` is skipped in CI because
  UI tests are slow and flaky on hosted simulators. Run them locally in Xcode;
  the shared scheme still includes them.
- **Shared scheme.** CI relies on
  `HealthKitGPXExporter.xcodeproj/xcshareddata/xcschemes/HealthKitGPXExporter.xcscheme`.
  Keep it shared: an unshared scheme lives in the gitignored `xcuserdata/` and
  CI cannot see it.
- **Xcode pin.** `XCODE_APP` in `ci.yml` must name an Xcode that the
  `macos-26` image still ships. See
  [actions/runner-images](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md).
- Superseded runs on the same ref are cancelled, and every job has a
  `timeout-minutes` cap.
- `renovate.json` extends the fleet preset, which pins GitHub Actions to commit
  SHAs and keeps them current. It only takes effect once this repository is
  listed in the fleet Renovate runner's repository list.

## TestFlight delivery

`testflight.yml` runs on every push to `main` and on manual dispatch. It never
runs on pull requests, because it reads signing secrets.

- **Gate.** A cheap `ubuntu-latest` job checks that `ASC_KEY_ID`,
  `ASC_ISSUER_ID` and `ASC_KEY_P8` are all set. If any is missing, it writes
  "TestFlight upload skipped" to the run summary and the workflow succeeds
  without starting the macOS job. This is the default until the owner
  finishes the steps below.
- **Signing.** Xcode automatic signing, authenticated with the App Store
  Connect API key (`-allowProvisioningUpdates -authenticationKeyPath/-ID/-IssuerID`).
  Distribution uses Apple's cloud-managed certificate, so no certificate or
  profile is stored in the repository or its secrets. The `.p8` is written to
  `$RUNNER_TEMP` with mode 600 and deleted in an `if: always()` step.
- **Build number.** `CURRENT_PROJECT_VERSION` is overridden to
  `BUILD_OFFSET + github.run_number` (offset 100, above the project file's
  build 2 and any hand uploads). `MARKETING_VERSION` stays owned by the project
  file; bump it there for a new version. `ci/ExportOptions.plist` sets
  `manageAppVersionAndBuildNumber` to false so Xcode keeps that number.
- **Upload.** `xcodebuild -exportArchive` with `ci/ExportOptions.plist`
  (`method` app-store-connect, `destination` upload) uploads directly. No
  fastlane or third-party actions.
- **Concurrency.** Runs on `main` queue rather than cancel: a cancelled upload
  is worse than a late one.

### Owner setup (one time)

Run these yourself. Do not hand the key or the `gh secret set` commands to an
agent.

1. **Merge `testflight.yml` to `main` first.** `gh workflow run` only finds a
   workflow that exists on the default branch. Until step 5, every push to
   `main` runs the gate job and skips the upload.
2. **App ID capabilities.** In Certificates, Identifiers & Profiles →
   Identifiers → `com.minghsuy.HealthKitGPXExporter`, make sure these are
   enabled, matching `HealthKitGPXExporter.entitlements`:
   - HealthKit. The v2 branch also needs HealthKit Background Delivery once it
     merges; `main` only needs plain HealthKit.
   - iCloud with CloudDocuments, and the container
     `iCloud.com.minghsuy.HealthKitGPXExporter` assigned. If it does not exist,
     create it under Identifiers → iCloud Containers.
     `-allowProvisioningUpdates` can usually sync capabilities, but create
     these by hand if the first archive fails on them.
3. **App record.** In App Store Connect → Apps → "+" → New App, create the
   iOS app with bundle ID `com.minghsuy.HealthKitGPXExporter`. Uploads fail
   without an app record.
4. **API key.** In App Store Connect → Users and Access → Integrations →
   App Store Connect API → Team Keys, generate a key with the **Admin** role.
   Automatic signing through the API needs Certificates, Identifiers &
   Profiles access and cloud-managed distribution certificate access. Admin
   has both by default; a lower role is unverified here. Note the Key ID and
   the Issuer ID, and download `AuthKey_XXXX.p8`. Apple lets you download it
   only once.
5. **Secrets.** From a checkout of this repository:

   ```bash
   ! gh secret set ASC_KEY_ID          # paste the Key ID
   ! gh secret set ASC_ISSUER_ID       # paste the Issuer ID
   ! gh secret set ASC_KEY_P8 < AuthKey_XXXX.p8
   ```

   Then store or delete the local `.p8`. Do not commit it.
6. **Try it:** `gh workflow run testflight.yml`, then `gh run watch`. The
   build appears in App Store Connect → TestFlight after processing, which
   often takes 5–30 minutes.

### Owner decision: export compliance

`Info.plist` does not set `ITSAppUsesNonExemptEncryption`, and the generated
Info.plist does not add it either. Until it is set, TestFlight asks the
encryption question for every uploaded build, and the build cannot go to
testers until someone answers. An app whose only encryption is HTTPS through
Apple's system frameworks usually qualifies as exempt, which would mean adding
`ITSAppUsesNonExemptEncryption = NO`. This is a legal declaration, so CI leaves
it for the owner to decide and add.

### Unverified until the first real run

These need a Mac or a live run, so they have not been checked:

- Whether `-allowProvisioningUpdates` with an API key creates a new Apple
  Development certificate on each fresh runner. If Certificates starts
  filling with "Created via API" entries, revoke the stale ones.
- Whether the iCloud container needs to exist before the first archive
  (step 2).
- Whether the Admin role is strictly required, or whether a lower-role key
  granted "Access to Cloud Managed Distribution Certificate" is enough.

References: `man xcodebuild` (`-allowProvisioningUpdates`,
`-authenticationKey*`); WWDC21 session 10204, "Distribute apps in Xcode with
cloud signing" (<https://developer.apple.com/videos/play/wwdc2021/10204/>);
Apple Account Help, "Cloud-managed certificates"
(<https://developer.apple.com/help/account/certificates/cloud-managed-certificates>).
