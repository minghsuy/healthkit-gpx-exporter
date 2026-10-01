import Foundation
import CoreLocation

/// Where a workout came from, taken from `HKWorkout.sourceRevision.source`.
/// Plain values so the serializer stays testable without HealthKit.
struct GPXWorkoutSource: Equatable {
    let name: String
    let bundleIdentifier: String
}

/// Time spent in one zone. A nil bound means the zone is open on that side.
struct GPXZoneDuration: Equatable {
    let index: Int
    let minimum: Double?
    let maximum: Double?
    let seconds: TimeInterval
}

/// Time-in-zone for one quantity type, e.g. heart rate in count/min.
struct GPXZoneSummary: Equatable {
    let type: String
    let unit: String
    let zones: [GPXZoneDuration]
}

/// The pause and resume kinds of `HKWorkoutEvent`. Laps, markers and
/// segments are left out: they do not change whether the rider is moving.
enum GPXWorkoutEventType: String, Equatable {
    case pause
    case resume
    /// Auto-pause: the recorder detected that the rider stopped.
    case motionPaused
    case motionResumed
}

struct GPXWorkoutEvent: Equatable {
    let type: GPXWorkoutEventType
    let time: Date
}

/// The workout's own clock, from `HKWorkout`. A GPX track ends at its last
/// route point, which can be long before the workout ended (the recorder
/// logs few points while the rider stands still), so these are what tell a
/// reader the real start, end and moving time.
struct GPXWorkoutTiming: Equatable {
    let start: Date
    let end: Date
    /// HKWorkout.duration as the source app saved it. Apple Watch workouts
    /// (HKWorkoutBuilder) leave out paused intervals; other apps may not.
    let duration: TimeInterval
    /// Metres; nil when HealthKit has no total distance.
    var totalDistanceMeters: Double?
    var events: [GPXWorkoutEvent] = []
}

struct GPXWorkoutMetadata: Equatable {
    /// HKWorkout.uuid: the same across re-exports of one workout. The same
    /// ride recorded by two apps has two UUIDs.
    var workoutUUID: UUID?
    var timing: GPXWorkoutTiming?
    var source: GPXWorkoutSource?
    var zoneSummaries: [GPXZoneSummary] = []
}

struct GPXSerializer {
    /// Namespace of this app's `<metadata><extensions>` elements. The server
    /// may read these (its ride matching is time-based today), so renaming an
    /// element or this URI is a format change.
    static let extensionNamespace = "https://github.com/minghsuy/healthkit-gpx-exporter/gpx/v1"

    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private let nameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    func serialize(
        workoutDate: Date,
        matchedData: [MatchedDataPoint],
        metadata: GPXWorkoutMetadata? = nil
    ) -> String {
        let name = "Cycling \(nameFormatter.string(from: workoutDate))"
        let timeStr = dateFormatter.string(from: workoutDate)

        // The server tells a recorded ride from a planned route by the creator
        // prefix "HealthKitGPXExporter"; keep that prefix. The version marks
        // the format: 2.1 and later always carry the workout times.
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1"
             creator="HealthKitGPXExporter/2.1"
             xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1"
             xmlns:hkx="\(Self.extensionNamespace)"
             xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
             xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">
          <metadata>
            \(xmlTag("name", value: name))
        """

        // GPX 1.1 fixes the order of <metadata> children: name, desc, ...,
        // time, ..., extensions last.
        if let source = metadata?.source {
            let desc = "Recorded by \(source.name) (\(source.bundleIdentifier))"
            xml += "\n    \(xmlTag("desc", value: desc))"
        }
        xml += "\n    \(xmlTag("time", value: timeStr))"
        xml += metadataExtensions(metadata)
        xml += "\n  </metadata>"
        xml += "\n  <trk>"
        xml += "\n    \(xmlTag("name", value: name))"
        xml += "\n    <type>cycling</type>"
        xml += "\n    <trkseg>"

        for point in matchedData {
            let lat = String(format: "%.6f", point.location.coordinate.latitude)
            let lon = String(format: "%.6f", point.location.coordinate.longitude)
            let ele = String(format: "%.1f", point.location.altitude)
            let time = dateFormatter.string(from: point.location.timestamp)

            let attributes = [("lat", lat), ("lon", lon)]
            xml += "\n      \(xmlOpenTag("trkpt", attributes: attributes))"
            xml += "\n        \(xmlTag("ele", value: ele))"
            xml += "\n        \(xmlTag("time", value: time))"

            if let hr = point.heartRate {
                xml += "\n        <extensions>"
                xml += "\n          <gpxtpx:TrackPointExtension>"
                xml += "\n            \(xmlTag("gpxtpx:hr", value: "\(hr)"))"
                xml += "\n          </gpxtpx:TrackPointExtension>"
                xml += "\n        </extensions>"
            }

            xml += "\n      </trkpt>"
        }

        xml += "\n    </trkseg>"
        xml += "\n  </trk>"
        xml += "\n</gpx>\n"

        return xml
    }

    private func metadataExtensions(_ metadata: GPXWorkoutMetadata?) -> String {
        guard let metadata,
              metadata.workoutUUID != nil || metadata.timing != nil
                || metadata.source != nil || !metadata.zoneSummaries.isEmpty else {
            return ""
        }

        var xml = "\n    <extensions>"
        if let workoutUUID = metadata.workoutUUID {
            xml += "\n      \(xmlTag("hkx:workoutUUID", value: workoutUUID.uuidString))"
        }
        if let timing = metadata.timing {
            xml += timingElements(timing)
        }
        if let source = metadata.source {
            xml += "\n      <hkx:source>"
            xml += "\n        \(xmlTag("hkx:name", value: source.name))"
            xml += "\n        \(xmlTag("hkx:bundleIdentifier", value: source.bundleIdentifier))"
            xml += "\n      </hkx:source>"
        }
        for summary in metadata.zoneSummaries {
            let attributes = [("type", summary.type), ("unit", summary.unit)]
            xml += "\n      \(xmlOpenTag("hkx:zones", attributes: attributes))"
            for zone in summary.zones {
                var zoneAttributes = [("index", "\(zone.index)")]
                if let minimum = zone.minimum {
                    zoneAttributes.append(("min", String(format: "%.1f", minimum)))
                }
                if let maximum = zone.maximum {
                    zoneAttributes.append(("max", String(format: "%.1f", maximum)))
                }
                zoneAttributes.append(("seconds", String(format: "%.0f", zone.seconds)))
                xml += "\n        \(xmlEmptyTag("hkx:zone", attributes: zoneAttributes))"
            }
            xml += "\n      </hkx:zones>"
        }
        xml += "\n    </extensions>"
        return xml
    }

    private func timingElements(_ timing: GPXWorkoutTiming) -> String {
        var xml = "\n      \(xmlTag("hkx:workoutStart", value: dateFormatter.string(from: timing.start)))"
        xml += "\n      \(xmlTag("hkx:workoutEnd", value: dateFormatter.string(from: timing.end)))"
        xml += "\n      \(xmlTag("hkx:workoutDuration", value: String(format: "%.0f", timing.duration)))"
        if let meters = timing.totalDistanceMeters {
            xml += "\n      \(xmlTag("hkx:totalDistance", value: String(format: "%.1f", meters)))"
        }
        // No element at all without events: an empty <hkx:events/> would
        // read as "recorded, never paused", which the source may not know.
        guard !timing.events.isEmpty else { return xml }
        xml += "\n      <hkx:events>"
        for event in timing.events.sorted(by: { $0.time < $1.time }) {
            let attributes = [("type", event.type.rawValue), ("time", dateFormatter.string(from: event.time))]
            xml += "\n        \(xmlEmptyTag("hkx:event", attributes: attributes))"
        }
        xml += "\n      </hkx:events>"
        return xml
    }

    private func xmlTag(_ name: String, value: String) -> String {
        "<\(name)>\(escapeXML(value))</\(name)>"
    }

    private func xmlOpenTag(_ name: String, attributes: [(String, String)]) -> String {
        "<\(name) \(attributeString(attributes))>"
    }

    private func xmlEmptyTag(_ name: String, attributes: [(String, String)]) -> String {
        "<\(name) \(attributeString(attributes))/>"
    }

    private func attributeString(_ attributes: [(String, String)]) -> String {
        attributes.map { "\($0.0)=\"\(escapeXML($0.1))\"" }.joined(separator: " ")
    }

    /// Also drops characters XML 1.0 forbids even when escaped: controls
    /// below U+0020 other than tab, LF and CR, and U+FFFE/U+FFFF. One in a
    /// device or app name would make the whole file unparseable.
    private func escapeXML(_ string: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: string.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x9, 0xA, 0xD:
                return true
            case 0x0..<0x20, 0xFFFE, 0xFFFF:
                return false
            default:
                return true
            }
        })
        return String(scalars)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
