# HealthKit GPX Exporter

An iOS app that exports cycling workouts from Apple Health to GPX files, with
the full route and matched heart rate. Files go to
`iCloud Drive/Bike-Ride-Analyzer/imports/`, or to the app's Documents folder
when iCloud Drive is off. The app makes no network calls and has no
third-party dependencies.

## GPX v2 metadata

Version 2.0 adds to each file's `<metadata>` the app that recorded the
workout (from `HKWorkout.sourceRevision.source`) and the HealthKit workout
UUID. The source appears as a human-readable `<desc>` and, with the UUID, as
structured elements in the
`https://github.com/minghsuy/healthkit-gpx-exporter/gpx/v1` namespace
(example values):

```xml
<metadata>
  <name>Cycling 2026-09-30 12:06</name>
  <desc>Recorded by Example Recorder (com.example.recorder)</desc>
  <time>2026-09-30T19:06:00Z</time>
  <extensions>
    <hkx:workoutUUID>0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9</hkx:workoutUUID>
    <hkx:source>
      <hkx:name>Example Recorder</hkx:name>
      <hkx:bundleIdentifier>com.example.recorder</hkx:bundleIdentifier>
    </hkx:source>
  </extensions>
</metadata>
```

- `<metadata>` children follow the GPX 1.1 order: name, desc, time,
  extensions.
- **`hkx:workoutUUID`** stays the same when a workout is exported again, so a
  reader may use it to spot re-exports. The same ride recorded by two apps
  (say a watch and a bike app) has two UUIDs; matching those is the reader's
  job, by overlapping time, not by UUID.
- **`creator`** is now `HealthKitGPXExporter/2.0`; match on the
  `HealthKitGPXExporter` prefix.
- **Filenames** are `workout_yyyy-MM-dd_HHmmss_<first 8 of the workout
  UUID>.gpx`, so two workouts that start in the same second no longer
  overwrite each other. v1 files keep their names.
- **Text cleanup.** Characters that XML 1.0 forbids (control characters
  other than tab, LF and CR, and U+FFFE/U+FFFF) are dropped from text values,
  so an odd app or device name cannot make a file unparseable.
- **Heart-rate and power zones (iOS 27).** On iOS 27 the time in each zone
  from `HKWorkout.zoneGroupsByType` is written as `<hkx:zones>` elements.
  This code is compiled only with Xcode 27 (Swift 6.4) or later.
- **Privacy.** The source name can be a personal device name, such as
  "Alex's Apple Watch". It is written into every file, so keep that in mind
  when sharing them.
