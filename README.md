# HealthKit GPX Exporter

An iOS app that exports cycling workouts from Apple Health to GPX files, with
the full route and matched heart rate. Files go to
`iCloud Drive/Bike-Ride-Analyzer/imports/`, or to the app's Documents folder
when iCloud Drive is off. The app has no third-party dependencies.

## v2

- **Source app in the GPX.** `<metadata>` carries the app that recorded the
  workout, from `HKWorkout.sourceRevision.source`, as a human-readable
  `<desc>` and as structured elements in the
  `https://github.com/minghsuy/healthkit-gpx-exporter/gpx/v1` namespace
  (example values):

  ```xml
  <metadata>
    <name>Cycling 2026-09-30 12:06</name>
    <desc>Recorded by Example Recorder (com.example.recorder)</desc>
    <time>2026-09-30T19:06:00Z</time>
    <extensions>
      <hkx:source>
        <hkx:name>Example Recorder</hkx:name>
        <hkx:bundleIdentifier>com.example.recorder</hkx:bundleIdentifier>
      </hkx:source>
    </extensions>
  </metadata>
  ```

  The `creator` attribute is now `HealthKitGPXExporter/2.0`; match on the
  `HealthKitGPXExporter` prefix.
- **Automatic export.** HealthKit background delivery wakes the app when a
  cycling workout is saved. The app exports workouts added since its last
  check that are newer than the last export (the same rule as "Export All
  New"). On the very first run with no export history it only records a
  starting point and exports nothing; use "Export All New" for history. A
  workout whose route is not in HealthKit yet is retried on later wakes for
  up to seven days.
- **Optional upload, off by default.** In Settings you can turn on upload,
  enter an `https://` server URL, and optionally save a bearer token, which is
  kept in the Keychain. Each exported file is then also POSTed as
  `multipart/form-data` (field `gpx`) to `{server URL}/api/v1/rides/gpx`.
  Data goes only to the URL you enter. Failed uploads stay queued and retry on
  the next launch or background wake.
- **Heart-rate and power zones (iOS 27).** On iOS 27 the time in each zone
  from `HKWorkout.zoneGroupsByType` is written as `<hkx:zones>`. This code is
  compiled only with Xcode 27 (Swift 6.4) or later.
