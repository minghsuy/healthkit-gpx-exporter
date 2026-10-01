# HealthKit GPX Exporter

An iOS app that exports cycling workouts from Apple Health to GPX files, with
the full route and matched heart rate. Files go to the app's iCloud container,
shown in iCloud Drive as `HealthKitGPXExporter/Bike-Ride-Analyzer/imports/`
(on a Mac: `~/Library/Mobile Documents/iCloud~com~minghsuy~HealthKitGPXExporter/Documents/Bike-Ride-Analyzer/imports/`),
which needs iCloud Drive turned on. With iCloud Drive off, an export lands in
the app's private Documents folder, which you cannot browse, so it is not
treated as done (see "Automatic export"). The app itself makes
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
    <hkx:workoutStart>2026-09-30T19:06:00Z</hkx:workoutStart>
    <hkx:workoutEnd>2026-09-30T20:21:00Z</hkx:workoutEnd>
    <hkx:workoutDuration>3780</hkx:workoutDuration>
    <hkx:totalDistance>21234.6</hkx:totalDistance>
    <hkx:events>
      <hkx:event type="pause" time="2026-09-30T19:26:00Z"/>
      <hkx:event type="resume" time="2026-09-30T19:36:00Z"/>
      <hkx:event type="motionPaused" time="2026-09-30T19:56:00Z"/>
      <hkx:event type="motionResumed" time="2026-09-30T19:58:00Z"/>
    </hkx:events>
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
- **Workout times (2.1).** `hkx:workoutStart` and `hkx:workoutEnd` are the
  workout's own `startDate` and `endDate` (ISO-8601 UTC), and
  `hkx:workoutDuration` is `HKWorkout.duration` in seconds, which excludes
  pauses. `hkx:totalDistance` is in metres and appears only when HealthKit
  has a total distance. The track alone cannot show these: it ends at its
  last route point, and a recorder logs few points while the rider stands
  still, so a workout left running after the ride looks shorter than it was.
- **Pause events (2.1).** `<hkx:events>` lists the workout's `pause`,
  `resume`, `motionPaused` and `motionResumed` (auto-pause) events in time
  order. Laps, markers and segments are left out, since they do not change
  whether the rider is moving. When the workout has no such events,
  `<hkx:events>` is omitted entirely, rather than written empty.
- **Reading these fields:**
  - No `<hkx:events>` means HealthKit holds no pause or resume events for
    this workout, not that the rider never stopped: some recorders do not
    log pauses.
  - `hkx:workoutDuration` is the source app's `HKWorkout.duration`. Apple
    Watch workouts (recorded with `HKWorkoutBuilder`) leave out paused
    intervals; other apps may include them.
  - If `workoutDuration` is shorter than `workoutEnd` minus `workoutStart`
    and there are no events, assume pauses happened that were not logged.
  - Events are points in time (`HKWorkoutEvent.dateInterval.start`), and
    pause and resume need not balance or nest. A `pause` with no later
    `resume` runs to `workoutEnd`; a `resume` with no earlier `pause` is
    ignored. Manual pauses (`pause`/`resume`) and auto-pauses
    (`motionPaused`/`motionResumed`) are independent and can overlap: the
    rider is moving when neither kind of pause is in effect.
  - `hkx:workoutStart` equals `<metadata><time>`; both come from the
    workout's `startDate`.
- These let the bike-ride-analyzer server compute exact riding time, trim
  idle time before the first resume or after the last movement, and match
  and blend recordings of the same ride (bike-ride-analyzer#883).
- **`creator`** is now `HealthKitGPXExporter/2.1`; match on the
  `HealthKitGPXExporter` prefix. The version marks the format: from 2.1,
  `hkx:workoutStart`, `hkx:workoutEnd` and `hkx:workoutDuration` are always
  present.
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
- **Complete routes only.** HealthKit saves a route after its workout, and
  has no "route finished" flag. Export waits until 10 minutes after the
  later of the workout's end and when the app first saw it, so a ride that
  another app syncs days late still gets 10 minutes for its route to arrive.
  It then joins every route sample of the workout in time order (a pause or
  GPS gap can split a route into several). A workout that is not settled
  yet, or has no route yet, is retried when a route is saved and on later
  wakes, for up to seven days after the app first sees it. Without such a
  wake, it waits for the next one or the next app launch. A manual export
  of a ride that has not settled still writes the file, but is not marked
  done: background export re-exports it once settled, overwriting the same
  file, and the export message says so.
- **Done means iCloud Drive.** An export counts as done only once the file is
  in iCloud Drive, for background and manual exports alike. The app's own
  Documents folder is not visible to you, so a file there reaches nobody.
  With iCloud Drive off, background export writes nothing: new workouts wait
  on the retry list, the sync position stays put, and Settings shows
  "iCloud Drive unavailable; N waiting". A manual export with iCloud Drive
  off reports "saved on this iPhone only"; those workouts stay in "Export
  All New". While any workout waits (for iCloud Drive or for its route to
  settle), the sync position is not moved forward.
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

### Checking it on the phone

These can only be verified on a device:

1. After a ride, Settings > Background Sync first shows "1 waiting for the
   route to settle" until 10 minutes after it ended, then the workout is
   exported on the next wake or launch.
2. A ride with a pause exports as one track containing every route segment.
3. With iCloud Drive turned off, Settings > Background Sync shows "iCloud
   Drive unavailable; N waiting", no file is written, and the workouts export
   to iCloud Drive on the first wake or launch after it is back on. A manual
   export with iCloud Drive off reports "saved on this iPhone only", and the
   workouts stay in "Export All New".
4. A ride another app syncs hours late (for example the Bosch app) still
   exports with its full route, at the first wake or app launch at least 10
   minutes after it appears in Health.
5. The first launch after installing takes a baseline and exports nothing.
6. Exporting a ride manually within 10 minutes of finishing says it stays in
   "Export All New" until its route is complete; a later background export
   overwrites the file.
