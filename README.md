# HealthKit GPX Exporter

HealthKit GPX Exporter is a privacy-first Apple-platform app for exporting
cycling workout routes and heart-rate samples from Apple Health to GPX 1.1.
The app has no third-party dependencies, analytics, or app-initiated network
calls. Files written to iCloud Drive may be synchronized by Apple's iCloud
service according to the user's device and account settings.

Exports are written to:

```text
iCloud Drive/Bike-Ride-Analyzer/imports/
```

If iCloud Drive is unavailable, the current code writes to its sandboxed local
documents directory. The app does not yet expose a share/document-picker path
for that fallback, so retrieving those files is a known release blocker rather
than a supported user workflow.

## Requirements

- Xcode 26.2 or newer
- iOS or iPadOS 26.2 or newer
- An Apple device with HealthKit data for end-to-end validation
- A configured Apple developer team, HealthKit entitlement, and iCloud
  container for device installation

## Build and test

Open
`HealthKitGPXExporter/HealthKitGPXExporter.xcodeproj` in Xcode, select the
`HealthKitGPXExporter` scheme, and run it on a compatible device or simulator.

For a signed physical-device build:

1. Join an Apple Developer Program team and select that team under **Signing &
   Capabilities** for all three targets.
2. Confirm that `com.minghsuy.HealthKitGPXExporter` is available to that team,
   or replace every target bundle identifier with identifiers owned by your
   team.
3. Register the app identifier with HealthKit and iCloud capabilities.
4. Register `iCloud.com.minghsuy.HealthKitGPXExporter`, or replace that identifier
   consistently in `Info.plist` and `HealthKitGPXExporter.entitlements`.
5. Enable automatic signing (or install reviewed profiles manually), then build
   to a supported physical iPhone/iPad. Do not commit certificates, profiles,
   App Store Connect keys, or passwords.

Simulator CI deliberately disables signing and cannot validate those account
registrations or capabilities.

The same unsigned simulator build and unit-test gate used in CI can be run from
macOS:

```bash
DEVELOPER_DIR=/Applications/Xcode_26.2.app/Contents/Developer \
  ./scripts/ci-test.sh
```

Release-contract checks are portable:

```bash
./scripts/test-release-preflight.sh
./scripts/release-preflight.sh --candidate
```

CI compiles Debug and Release for an iOS simulator, runs the full unit/UI test
suite, creates an unsigned Release archive for metadata inspection, and confirms
that the archive is not signed. A simulator cannot validate real HealthKit
permissions, HealthKit routes, or the configured iCloud container.

## HealthKit permissions

On first launch, the app asks for read access to:

- cycling workouts;
- workout routes; and
- heart-rate samples.

The app requests no HealthKit write access. Apple intentionally does not reveal
whether a user denied read access to a specific HealthKit type, so a denied type
may appear as missing or empty data rather than a distinct authorization error.
Permissions can be reviewed in the Health app or system Privacy & Security
settings.

## Exporting

1. Grant the requested HealthKit read access.
2. Wait for cycling workouts to load.
3. Select individual workouts and choose **Export Selected**, or choose
   **Export All New**.
4. Find the GPX files under
   `iCloud Drive/Bike-Ride-Analyzer/imports/`. Do not rely on the sandboxed local
   fallback until the app provides a user-accessible retrieval path.
5. Validate important exports in an independent GPX consumer before deleting or
   changing the source data.

Each GPX contains the cycling track's coordinates, timestamps, elevation, and
matched heart-rate samples when a sample is within five seconds of a route
point. A workout with no HealthKit route is silently skipped and produces no
file in the current implementation; that behavior must be included in
physical-device release validation.

The app records the time of a successful export to identify newer workouts.
**Reset Export History** in Settings clears that marker; it does not delete GPX
files.

## Troubleshooting

- **No cycling workouts:** confirm that Apple Health contains cycling workouts
  and that workout access is enabled for the app.
- **Route or heart rate missing:** confirm those permissions separately. Some
  workouts do not contain a recorded route or heart-rate samples.
- **iCloud shows “Not Connected”:** enable iCloud Drive for the device and app.
  The current local fallback has no user-facing retrieval path and its success
  message can still say “iCloud Drive”; both are blockers recorded in the
  release evidence checklist.
- **An export fails:** keep the HealthKit source workout and retry. Do not assume
  the “last export” marker proves that every earlier workout has a valid file.
- **The app does not install from GitHub:** expected. GitHub releases are
  source-only and contain no signed application.

## Releases

GitHub releases contain a deterministic source archive and its SHA-256 file.
They do not contain an installable or Apple-signed app. The `v1.0.0` tag is
blocked until the committed manual evidence checklist is complete. See
[DISTRIBUTION.md](DISTRIBUTION.md) for what CI proves and the steps still
required before TestFlight, App Store, or source release.

## Privacy

Workout routes and heart-rate data are sensitive. The app reads only the
HealthKit types required for export and writes GPX files to the user's own
iCloud or local documents container. It has no analytics or app-initiated
network calls, although iCloud Drive may synchronize files through Apple.
Contributors should preserve this user-controlled boundary.

## License

MIT
