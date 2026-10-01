import Testing
import Foundation
import CoreLocation
import HealthKit
@testable import HealthKitGPXExporter

/// The app target defaults to MainActor isolation, so its types are
/// MainActor-isolated; the suite runs there too.
@MainActor
struct GPXSerializerTests {
    private let workoutDate = Date(timeIntervalSince1970: 1_790_000_000)

    private func point(heartRate: Int?) -> MatchedDataPoint {
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.123456, longitude: -122.654321),
            altitude: 12.34,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            timestamp: workoutDate
        )
        return MatchedDataPoint(location: location, heartRate: heartRate)
    }

    private func metadataBlock(_ xml: String) throws -> String {
        let start = try #require(xml.range(of: "<metadata>"))
        let end = try #require(xml.range(of: "</metadata>"))
        return String(xml[start.lowerBound..<end.upperBound])
    }

    @Test func withoutMetadataHasNoSourceOrExtensionsInMetadata() throws {
        let xml = GPXSerializer().serialize(workoutDate: workoutDate, matchedData: [point(heartRate: 140)])
        let metadata = try metadataBlock(xml)

        #expect(!metadata.contains("<desc>"))
        #expect(!metadata.contains("<extensions>"))
        #expect(xml.contains("creator=\"HealthKitGPXExporter/2.0\""))
        #expect(xml.contains("<gpxtpx:hr>140</gpxtpx:hr>"))
    }

    @Test func sourceIsWrittenToDescAndExtensions() throws {
        let metadata = GPXWorkoutMetadata(
            source: GPXWorkoutSource(name: "Example Recorder", bundleIdentifier: "com.example.recorder")
        )
        let xml = GPXSerializer().serialize(workoutDate: workoutDate, matchedData: [point(heartRate: nil)], metadata: metadata)
        let block = try metadataBlock(xml)

        #expect(block.contains("<desc>Recorded by Example Recorder (com.example.recorder)</desc>"))
        #expect(block.contains("<hkx:name>Example Recorder</hkx:name>"))
        #expect(block.contains("<hkx:bundleIdentifier>com.example.recorder</hkx:bundleIdentifier>"))
        #expect(xml.contains("xmlns:hkx=\"\(GPXSerializer.extensionNamespace)\""))
    }

    @Test func workoutUUIDIsWrittenToExtensions() throws {
        let uuid = try #require(UUID(uuidString: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9"))
        let metadata = GPXWorkoutMetadata(workoutUUID: uuid)
        let xml = GPXSerializer().serialize(workoutDate: workoutDate, matchedData: [], metadata: metadata)
        let block = try metadataBlock(xml)

        #expect(block.contains("<extensions>"))
        #expect(block.contains("<hkx:workoutUUID>0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9</hkx:workoutUUID>"))
        #expect(!block.contains("<hkx:source>"))
        #expect(!block.contains("<desc>"))
    }

    private func at(minutes: Double) -> Date {
        workoutDate.addingTimeInterval(minutes * 60)
    }

    private func timing(events: [GPXWorkoutEvent] = [], distance: Double? = 21_234.56) -> GPXWorkoutTiming {
        GPXWorkoutTiming(
            start: workoutDate,
            end: at(minutes: 75),
            duration: 3_605.4,
            totalDistanceMeters: distance,
            events: events
        )
    }

    @Test func timingFieldsFollowWorkoutUUIDInOrder() throws {
        let uuid = try #require(UUID(uuidString: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9"))
        let metadata = GPXWorkoutMetadata(
            workoutUUID: uuid,
            timing: timing(),
            source: GPXWorkoutSource(name: "Workout", bundleIdentifier: "com.apple.health")
        )
        let xml = GPXSerializer().serialize(workoutDate: workoutDate, matchedData: [], metadata: metadata)
        let block = try metadataBlock(xml)

        #expect(block.contains("<hkx:workoutStart>2026-09-21T14:13:20Z</hkx:workoutStart>"))
        #expect(block.contains("<hkx:workoutEnd>2026-09-21T15:28:20Z</hkx:workoutEnd>"))
        #expect(block.contains("<hkx:workoutDuration>3605</hkx:workoutDuration>"))
        #expect(block.contains("<hkx:totalDistance>21234.6</hkx:totalDistance>"))

        let order = ["<hkx:workoutUUID>", "<hkx:workoutStart>", "<hkx:workoutEnd>",
                     "<hkx:workoutDuration>", "<hkx:totalDistance>", "<hkx:source>"]
        let positions = try order.map { try #require(block.range(of: $0)).lowerBound }
        #expect(positions == positions.sorted())
    }

    @Test func totalDistanceIsOmittedWhenMissing() throws {
        let metadata = GPXWorkoutMetadata(timing: timing(distance: nil))
        let block = try metadataBlock(GPXSerializer().serialize(workoutDate: workoutDate, matchedData: [], metadata: metadata))

        #expect(block.contains("<hkx:workoutDuration>"))
        #expect(!block.contains("totalDistance"))
    }

    @Test func eventsAreWrittenInTimeOrder() throws {
        let events = [
            GPXWorkoutEvent(type: .resume, time: at(minutes: 30)),
            GPXWorkoutEvent(type: .motionPaused, time: at(minutes: 50)),
            GPXWorkoutEvent(type: .pause, time: at(minutes: 20)),
            GPXWorkoutEvent(type: .motionResumed, time: at(minutes: 52))
        ]
        let metadata = GPXWorkoutMetadata(timing: timing(events: events))
        let block = try metadataBlock(GPXSerializer().serialize(workoutDate: workoutDate, matchedData: [], metadata: metadata))

        let expected = """
              <hkx:events>
                <hkx:event type="pause" time="2026-09-21T14:33:20Z"/>
                <hkx:event type="resume" time="2026-09-21T14:43:20Z"/>
                <hkx:event type="motionPaused" time="2026-09-21T15:03:20Z"/>
                <hkx:event type="motionResumed" time="2026-09-21T15:05:20Z"/>
              </hkx:events>
        """
        #expect(block.contains(expected))
    }

    @Test func noEventsMeansNoEventsElement() throws {
        let metadata = GPXWorkoutMetadata(timing: timing(events: []))
        let block = try metadataBlock(GPXSerializer().serialize(workoutDate: workoutDate, matchedData: [], metadata: metadata))

        #expect(block.contains("<hkx:workoutStart>"))
        #expect(!block.contains("events"))
        #expect(!block.contains("hkx:event"))
    }

    @Test func onlyPauseAndResumeEventTypesAreKept() {
        func event(_ type: HKWorkoutEventType, _ minutes: Double) -> HKWorkoutEvent {
            HKWorkoutEvent(type: type, dateInterval: DateInterval(start: at(minutes: minutes), duration: 0), metadata: nil)
        }
        let events = [
            event(.lap, 5),
            event(.motionResumed, 40),
            event(.marker, 10),
            event(.pause, 20),
            event(.segment, 25),
            event(.resume, 30),
            event(.motionPaused, 35),
            event(.pauseOrResumeRequest, 36)
        ]

        let kept = HealthKitManager.timingEvents(events)

        #expect(kept == [
            GPXWorkoutEvent(type: .pause, time: at(minutes: 20)),
            GPXWorkoutEvent(type: .resume, time: at(minutes: 30)),
            GPXWorkoutEvent(type: .motionPaused, time: at(minutes: 35)),
            GPXWorkoutEvent(type: .motionResumed, time: at(minutes: 40))
        ])
    }

    @Test func timingAndEventsRoundTripThroughXMLParser() throws {
        let metadata = GPXWorkoutMetadata(timing: timing(events: [
            GPXWorkoutEvent(type: .motionPaused, time: at(minutes: 50)),
            GPXWorkoutEvent(type: .pause, time: at(minutes: 20))
        ]))
        let xml = GPXSerializer().serialize(workoutDate: workoutDate, matchedData: [point(heartRate: 140)], metadata: metadata)

        let collector = ElementCollector()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldProcessNamespaces = true
        parser.delegate = collector
        let parsed = parser.parse()
        #expect(parsed)
        #expect(parser.parserError == nil)

        let namespace = GPXSerializer.extensionNamespace
        let iso = ISO8601DateFormatter()
        #expect(collector.text["\(namespace)|workoutStart"].flatMap(iso.date(from:)) == workoutDate)
        #expect(collector.text["\(namespace)|workoutEnd"].flatMap(iso.date(from:)) == at(minutes: 75))
        #expect(collector.text["\(namespace)|workoutDuration"] == "3605")
        let events = collector.attributes.filter { $0.element == "\(namespace)|event" }.map(\.values)
        #expect(events.map { $0["type"] } == ["pause", "motionPaused"])
        #expect(events.map { $0["time"].flatMap(iso.date(from:)) } == [at(minutes: 20), at(minutes: 50)])
    }

    @Test func metadataChildrenFollowGPXSchemaOrder() throws {
        let metadata = GPXWorkoutMetadata(
            source: GPXWorkoutSource(name: "Workout", bundleIdentifier: "com.apple.health")
        )
        let xml = GPXSerializer().serialize(workoutDate: workoutDate, matchedData: [], metadata: metadata)
        let block = try metadataBlock(xml)

        let name = try #require(block.range(of: "<name>"))
        let desc = try #require(block.range(of: "<desc>"))
        let time = try #require(block.range(of: "<time>"))
        let extensions = try #require(block.range(of: "<extensions>"))
        #expect(name.lowerBound < desc.lowerBound)
        #expect(desc.lowerBound < time.lowerBound)
        #expect(time.lowerBound < extensions.lowerBound)
    }

    @Test func sourceValuesAreXMLEscaped() throws {
        let metadata = GPXWorkoutMetadata(
            source: GPXWorkoutSource(name: "Tom & Jerry's <\"Ride\">", bundleIdentifier: "a&b")
        )
        let xml = GPXSerializer().serialize(workoutDate: workoutDate, matchedData: [], metadata: metadata)

        #expect(xml.contains("<hkx:name>Tom &amp; Jerry&apos;s &lt;&quot;Ride&quot;&gt;</hkx:name>"))
        #expect(xml.contains("<hkx:bundleIdentifier>a&amp;b</hkx:bundleIdentifier>"))
        #expect(!xml.contains("Jerry's"))
    }

    @Test func xmlIllegalCharactersAreStripped() throws {
        let name = "A\u{0}B\u{1}C\u{1F}D\u{FFFE}E\u{FFFF}F\tG"
        let metadata = GPXWorkoutMetadata(
            source: GPXWorkoutSource(name: name, bundleIdentifier: "com.example\u{8}.app")
        )
        let xml = GPXSerializer().serialize(workoutDate: workoutDate, matchedData: [], metadata: metadata)

        #expect(xml.contains("<hkx:name>ABCDEF\tG</hkx:name>"))
        #expect(xml.contains("<hkx:bundleIdentifier>com.example.app</hkx:bundleIdentifier>"))

        let parser = XMLParser(data: Data(xml.utf8))
        let parsed = parser.parse()
        #expect(parsed)
        #expect(parser.parserError == nil)
    }

    @Test func zoneSummariesAreWrittenWithOpenBoundsOmitted() throws {
        let metadata = GPXWorkoutMetadata(
            source: nil,
            zoneSummaries: [
                GPXZoneSummary(type: "heartRate", unit: "count/min", zones: [
                    GPXZoneDuration(index: 0, minimum: nil, maximum: 120, seconds: 300.4),
                    GPXZoneDuration(index: 1, minimum: 120, maximum: nil, seconds: 1200)
                ])
            ]
        )
        let xml = GPXSerializer().serialize(workoutDate: workoutDate, matchedData: [], metadata: metadata)
        let block = try metadataBlock(xml)

        #expect(block.contains("<hkx:zones type=\"heartRate\" unit=\"count/min\">"))
        #expect(block.contains("<hkx:zone index=\"0\" max=\"120.0\" seconds=\"300\"/>"))
        #expect(block.contains("<hkx:zone index=\"1\" min=\"120.0\" seconds=\"1200\"/>"))
        #expect(!block.contains("<hkx:source>"))
        #expect(!block.contains("<desc>"))
    }

    @Test func outputIsWellFormedXMLWithNamespacedSource() throws {
        let uuid = UUID()
        let metadata = GPXWorkoutMetadata(
            workoutUUID: uuid,
            source: GPXWorkoutSource(name: "A & B", bundleIdentifier: "com.example.app"),
            zoneSummaries: [
                GPXZoneSummary(type: "cyclingPower", unit: "W", zones: [
                    GPXZoneDuration(index: 0, minimum: 0, maximum: 150, seconds: 60)
                ])
            ]
        )
        let xml = GPXSerializer().serialize(
            workoutDate: workoutDate,
            matchedData: [point(heartRate: 150), point(heartRate: nil)],
            metadata: metadata
        )

        let collector = ElementCollector()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldProcessNamespaces = true
        parser.delegate = collector
        let parsed = parser.parse()
        #expect(parsed)
        #expect(parser.parserError == nil)

        let namespace = GPXSerializer.extensionNamespace
        #expect(collector.text["\(namespace)|name"] == "A & B")
        #expect(collector.text["\(namespace)|bundleIdentifier"] == "com.example.app")
        #expect(collector.text["\(namespace)|workoutUUID"] == uuid.uuidString)
        #expect(collector.elements.filter { $0 == "http://www.topografix.com/GPX/1/1|trkpt" }.count == 2)
    }
}

/// Records every element as "namespaceURI|localName", its attributes, and
/// the text of leaf elements, so a test can assert what an XML consumer
/// would actually read.
private final class ElementCollector: NSObject, XMLParserDelegate {
    var elements: [String] = []
    var attributes: [(element: String, values: [String: String])] = []
    var text: [String: String] = [:]
    private var current = ""
    private var buffer = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        current = "\(namespaceURI ?? "")|\(elementName)"
        elements.append(current)
        attributes.append((current, attributeDict))
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let key = "\(namespaceURI ?? "")|\(elementName)"
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if key == current, !trimmed.isEmpty {
            text[key] = trimmed
        }
        buffer = ""
    }
}
