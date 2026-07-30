import CoreLocation
import Foundation
import HealthKit
import Testing
@testable import HealthKitGPXExporter

@MainActor
struct HealthKitGPXExporterTests {
    private let referenceDate = Date(timeIntervalSince1970: 1_735_689_600)

    @Test
    func serializerProducesValidGPXWithHeartRate() throws {
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.331_82, longitude: -122.031_18),
            altitude: 14.2,
            horizontalAccuracy: 3,
            verticalAccuracy: 4,
            timestamp: referenceDate.addingTimeInterval(10)
        )
        let gpx = GPXSerializer(appVersion: "1.0").serialize(
            workoutDate: referenceDate,
            matchedData: [MatchedDataPoint(location: location, heartRate: 147)]
        )

        #expect(gpx.contains(#"<gpx version="1.1""#))
        #expect(gpx.contains(#"creator="HealthKitGPXExporter/1.0""#))
        #expect(gpx.contains(#"lat="37.331820" lon="-122.031180""#))
        #expect(gpx.contains("<gpxtpx:hr>147</gpxtpx:hr>"))
        #expect(gpx.contains("<ele>14.2</ele>"))

        let parser = XMLParser(data: try #require(gpx.data(using: .utf8)))
        #expect(parser.parse())
    }

    @Test
    func serializerEscapesCreatorAttribute() throws {
        let gpx = GPXSerializer(appVersion: #"1.0"&<test>"#).serialize(
            workoutDate: referenceDate,
            matchedData: []
        )

        #expect(gpx.contains(#"creator="HealthKitGPXExporter/1.0&quot;&amp;&lt;test&gt;""#))
        let parser = XMLParser(data: try #require(gpx.data(using: .utf8)))
        #expect(parser.parse())
    }

    @Test
    func matcherUsesNearestHeartRateInsideTolerance() {
        let locations = [
            makeLocation(at: referenceDate),
            makeLocation(at: referenceDate.addingTimeInterval(20))
        ]
        let samples = [
            makeHeartRate(120, at: referenceDate.addingTimeInterval(2)),
            makeHeartRate(160, at: referenceDate.addingTimeInterval(12))
        ]

        let result = HeartRateMatcher().match(locations: locations, hrSamples: samples)

        #expect(result.count == 2)
        #expect(result[0].heartRate == 120)
        #expect(result[1].heartRate == nil)
    }

    @Test
    func matcherPreservesLocationsWhenHeartRateIsUnavailable() {
        let locations = [
            makeLocation(at: referenceDate),
            makeLocation(at: referenceDate.addingTimeInterval(5))
        ]

        let result = HeartRateMatcher().match(locations: locations, hrSamples: [])

        #expect(result.count == locations.count)
        #expect(result.allSatisfy { $0.heartRate == nil })
    }

    private func makeLocation(at date: Date) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37, longitude: -122),
            altitude: 0,
            horizontalAccuracy: 1,
            verticalAccuracy: 1,
            timestamp: date
        )
    }

    private func makeHeartRate(_ bpm: Double, at date: Date) -> HKQuantitySample {
        let unit = HKUnit.count().unitDivided(by: .minute())
        return HKQuantitySample(
            type: HKQuantityType(.heartRate),
            quantity: HKQuantity(unit: unit, doubleValue: bpm),
            start: date,
            end: date
        )
    }
}
