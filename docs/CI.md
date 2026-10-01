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
- **Environment.** Both jobs run in the `testflight` environment, and the
  secrets are environment secrets, which only jobs naming that environment can
  read. Its deployment-branch policy (main only, step 2 below) is what stops a
  pushed branch from editing this workflow to read them. If a run reaches the
  environment before the owner creates it, GitHub creates it automatically
  with no protection rules and no secrets, so the gate skips and the run stays
  green. Create it with the branch policy before adding any secrets.
- **Main only.** The upload job also requires `github.ref ==
  'refs/heads/main'`, so a manual dispatch from another branch never uploads.
  Once the branch policy exists, GitHub should reject that dispatch at the
  gate job, so the run shows red rather than skipping.
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
- **Concurrency.** Latest wins: one run at a time, and a newer push replaces
  an older queued run. The run in progress is never cancelled, because a
  cancelled upload is worse than a late one.
- **Re-runs.** Do not re-run a run that already uploaded. A re-run reuses its
  `run_number`, so App Store Connect rejects the duplicate build number.
  Dispatch a fresh run instead. Never rename or recreate `testflight.yml`,
  because that resets `run_number`; if it ever happens, raise `BUILD_OFFSET`
  above the last uploaded build.

### Owner setup (one time)

Run these yourself. Do not hand the key or the `gh secret set` commands to an
agent.

1. **Merge `testflight.yml` to `main` first.** `gh workflow run` only finds a
   workflow that exists on the default branch. Until step 6, every push to
   `main` runs the gate job and skips the upload.
2. **Environment.** Create `testflight` with deployment branches limited to
   `main` and no required reviewers: Settings → Environments → New
   environment "testflight" → Deployment branches and tags: Selected branches
   and tags → add `main`. Or, from a terminal:

   ```bash
   gh api -X PUT repos/minghsuy/healthkit-gpx-exporter/environments/testflight \
     --input - <<'JSON'
   {"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
   JSON
   gh api -X POST repos/minghsuy/healthkit-gpx-exporter/environments/testflight/deployment-branch-policies \
     -f name=main -f type=branch
   ```

   Do this before step 6. If a run already auto-created the environment, the
   same commands add the policy to it.
3. **App ID capabilities.** In Certificates, Identifiers & Profiles →
   Identifiers → `com.minghsuy.HealthKitGPXExporter`, make sure these are
   enabled, matching `HealthKitGPXExporter.entitlements`:
   - HealthKit. The v2 branch also needs HealthKit Background Delivery once it
     merges; `main` only needs plain HealthKit.
   - iCloud with CloudDocuments, and the container
     `iCloud.com.minghsuy.HealthKitGPXExporter` assigned. If it does not exist,
     create it under Identifiers → iCloud Containers.
     `-allowProvisioningUpdates` can usually sync capabilities, but create
     these by hand if the first archive fails on them.
4. **App record.** In App Store Connect → Apps → "+" → New App, create the
   iOS app with bundle ID `com.minghsuy.HealthKitGPXExporter`. Uploads fail
   without an app record.
5. **API key.** In App Store Connect → Users and Access → Integrations →
   App Store Connect API → Team Keys, generate a key with the **Admin** role.
   Automatic signing through the API needs Certificates, Identifiers &
   Profiles access and cloud-managed distribution certificate access. Admin
   has both by default; a lower role is unverified here. Note the Key ID and
   the Issuer ID, and download `AuthKey_<KEY_ID>.p8`. Apple lets you download
   it only once.
6. **Secrets.** Set them as `testflight` environment secrets. Do not also set
   them as repository secrets, because any workflow on any pushed branch can
   read repository secrets. The `!` prefix below is Claude Code's "run this in the current
   session" prefix. That session has no TTY, so `gh secret set` cannot prompt
   for a pasted value, and an empty secret would make the gate skip silently.
   These forms need no prompt. The Key ID and Issuer ID are identifiers, not
   secrets, so passing them with `--body` is fine:

   ```bash
   ! gh secret set ASC_KEY_ID --env testflight --body <KEY_ID>
   ! gh secret set ASC_ISSUER_ID --env testflight --body <ISSUER_ID>
   ! gh secret set ASC_KEY_P8 --env testflight < ~/Downloads/AuthKey_<KEY_ID>.p8
   ```

   Or run the same commands without the `!` in your own terminal. Verify that
   `gh secret list --env testflight` shows all three. Then store or delete the
   local `.p8`, and never commit it.
7. **App icon.** `Assets.xcassets/AppIcon.appiconset` has no images, and App
   Store Connect rejects an upload without an app icon. Add a 1024×1024
   AppIcon before the first dispatch.
8. **Try it:** `gh workflow run testflight.yml`, then `gh run watch`. The
   first run is a trial: expect a signing or upload issue to surface (see
   "Unverified" below). Once a run uploads, the build shows up in App Store
   Connect → TestFlight after processing.

### Export compliance (owner decision, 2026-09-30)

`Info.plist` sets `ITSAppUsesNonExemptEncryption = NO`. The owner declared it:
the app makes no network requests (iOS performs the iCloud Drive sync), and
any future upload to the owner's own server would use standard HTTPS through
Apple's system frameworks, which is exempt. With the key set, TestFlight no
longer asks the encryption question per build. Builds uploaded before the key
landed still need the question answered once in App Store Connect. Revisit
this only if the app adds its own cryptography; it is a legal declaration.

### Unverified until the first real run

These need a Mac or a live run, so they have not been checked:

- Whether `-allowProvisioningUpdates` with an API key creates a new Apple
  Development certificate on each fresh runner. If Certificates starts
  filling with "Created via API" entries, revoke the stale ones.
- Whether the iCloud container needs to exist before the first archive
  (step 3).
- Whether `-exportArchive` with `destination` upload authenticates the upload
  itself with the API key alone, with no Apple ID signed in to Xcode.
  Apple's sources confirm the key works for xcodebuild signing; the upload is
  inferred.
- Whether the upload passes App Store Connect validation. The missing app
  icon (step 7) is a known rejection; others may surface on the first run.
- Whether the Admin role is strictly required, or whether a lower-role key
  granted "Access to Cloud Managed Distribution Certificate" is enough.

References: `man xcodebuild` (`-allowProvisioningUpdates`,
`-authenticationKey*`); WWDC21 session 10204, "Distribute apps in Xcode with
cloud signing" (<https://developer.apple.com/videos/play/wwdc2021/10204/>);
Apple Account Help, "Cloud-managed certificates"
(<https://developer.apple.com/help/account/certificates/cloud-managed-certificates>);
GitHub Docs, "Managing environments for deployment" (a referenced environment
that does not exist is created with no protection rules or secrets) and the
REST "Deployment environments" and "Deployment branch policies" endpoints.
