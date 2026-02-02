import Foundation
import CoreLocation

struct GPXSerializer {
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

    func serialize(workoutDate: Date, matchedData: [MatchedDataPoint]) -> String {
        let name = "Cycling \(nameFormatter.string(from: workoutDate))"
        let timeStr = dateFormatter.string(from: workoutDate)

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1"
             creator="HealthKitGPXExporter/1.0"
             xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1"
             xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
             xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">
          <metadata>
            <name>\(escapeXML(name))</name>
            <time>\(timeStr)</time>
          </metadata>
          <trk>
            <name>\(escapeXML(name))</name>
            <type>cycling</type>
            <trkseg>
        """

        for point in matchedData {
            let lat = String(format: "%.6f", point.location.coordinate.latitude)
            let lon = String(format: "%.6f", point.location.coordinate.longitude)
            let ele = String(format: "%.1f", point.location.altitude)
            let time = dateFormatter.string(from: point.location.timestamp)

            xml += "\n      <trkpt lat=\"\(lat)\" lon=\"\(lon)\">"
            xml += "\n        <ele>\(ele)</ele>"
            xml += "\n        <time>\(time)</time>"

            if let hr = point.heartRate {
                xml += "\n        <extensions>"
                xml += "\n          <gpxtpx:TrackPointExtension>"
                xml += "\n            <gpxtpx:hr>\(hr)</gpxtpx:hr>"
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

    private func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
