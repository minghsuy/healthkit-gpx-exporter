# HealthKit GPX Exporter

An iOS app that exports cycling workouts from Apple Health to GPX files, with
the full route and matched heart rate. Files go to the app's iCloud container,
shown in iCloud Drive as `HealthKitGPXExporter/Bike-Ride-Analyzer/imports/`
(on a Mac: `~/Library/Mobile Documents/iCloud~com~minghsuy~HealthKitGPXExporter/Documents/Bike-Ride-Analyzer/imports/`),
or to the app's Documents folder when iCloud Drive is off. The app itself makes
no network requests (iOS syncs the iCloud folder) and has no third-party
dependencies.

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
  overwrite each other. v1 files are not renamed or removed, so re-exporting
  a ride v1 already exported, or exporting after Reset, writes a second file
  for that ride next to the v1 one.
- **Text cleanup.** Characters that XML 1.0 forbids (control characters
  other than tab, LF and CR, and U+FFFE/U+FFFF) are dropped from text values,
  so an odd app or device name cannot make a file unparseable.
- **Heart-rate and power zones (iOS 27).** On iOS 27 the time in each zone
  from `HKWorkout.zoneGroupsByType` is written as `<hkx:zones>` elements.
  This code is compiled only with Xcode 27 (Swift 6.4) or later.
- **Privacy.** The source name can be a personal device name, such as
  "Alex's Apple Watch". It is written into every file, so keep that in mind
  when sharing them.

## Automatic export

HealthKit background delivery wakes the app when a cycling workout, or a
workout route, is saved to Health. The app then exports every cycling
workout added since its last check, whatever the workout's start time, so a
ride that another app syncs hours later is still exported.

- **Exported once.** Exported workouts are tracked by HealthKit UUID in
  `exported-workouts.json` (Application Support). "Export All New" uses the
  same record, so neither path exports a workout again automatically, and
  the list updates as soon as either one exports. "Export Selected" re-exports
  on purpose.
- **First run.** The first background check only records a starting point
  and exports nothing. Use "Export All New" for the history; on an upgrade
  from v1, workouts that started before the last v1 export count as already
  exported.
- **Late routes.** HealthKit saves a route after its workout. A workout with
  no route yet is retried when the route is saved and on later wakes, for up
  to seven days after the app first sees it.
- **Errors are shown, not hidden.** Settings > Background Sync shows the
  last result when you open it. If the export record cannot be read, the app refuses to
  overwrite it and disables "Export All New"; "Reset Export History" clears
  the record, the sync anchor and the retry list.
- **Unsaved record.** If the export record cannot be written, the app does
  not move its sync position, "Last Export" or the retry list forward, and
  Settings says "export record could not be saved; will retry". A later wake
  covers the same workouts again; re-exporting one overwrites the same file,
  since filenames are fixed per workout.
- Background delivery needs the HealthKit Background Delivery capability on
  the App ID and only works on a device, not in the Simulator.
