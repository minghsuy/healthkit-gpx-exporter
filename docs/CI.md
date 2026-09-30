# CI

All jobs run on GitHub-hosted runners. This repository is public, so no job may
run on a self-hosted runner.

## What runs

| Workflow | Trigger | Checks |
|---|---|---|
| `ci.yml` | pull request, push to `main` | Builds the `HealthKitGPXExporter` scheme for an iOS Simulator (`macos-26`, Xcode 26.6, iPhone 17, newest installed iOS runtime) and runs the unit test target `HealthKitGPXExporterTests`. |
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
- **No network in tests.** The app makes network calls only when the user
  turns on upload in Settings, which is off by default. Unit tests cover the
  upload request building in plain Swift and never send a request.
- **iOS 27 code is not built here.** The zone export is behind
  `#if compiler(>=6.4)`. Xcode 26.6 ships Swift 6.3 and the iOS 26.5 SDK, so
  CI compiles without it. Moving `XCODE_APP` to Xcode 27 compiles it.
- Superseded runs on the same ref are cancelled, and every job has a
  `timeout-minutes` cap.
- `renovate.json` extends the fleet preset, which pins GitHub Actions to commit
  SHAs and keeps them current. It only takes effect once this repository is
  listed in the fleet Renovate runner's repository list.

## Later: signing and TestFlight

This CI does not sign, archive, or upload builds. Signed builds and TestFlight
delivery will be a separate workflow. It will authenticate with an App Store
Connect API key that the owner adds as repository secrets. Until then, nothing
in CI needs or reads a secret.
