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

struct GPXWorkoutMetadata: Equatable {
    var source: GPXWorkoutSource?
    var zoneSummaries: [GPXZoneSummary] = []
}

struct GPXSerializer {
    /// Namespace of this app's `<metadata><extensions>` elements. The server
    /// parses these, so renaming an element or this URI is a format change.
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
        // prefix "HealthKitGPXExporter"; keep that prefix.
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1"
             creator="HealthKitGPXExporter/2.0"
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
        guard let metadata, metadata.source != nil || !metadata.zoneSummaries.isEmpty else {
            return ""
        }

        var xml = "\n    <extensions>"
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

    private func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
