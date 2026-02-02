import Foundation
import HealthKit
import CoreLocation

struct MatchedDataPoint {
    let location: CLLocation
    let heartRate: Int?
}

struct HeartRateMatcher {
    private let tolerance: TimeInterval = 5.0

    func match(locations: [CLLocation], hrSamples: [HKQuantitySample]) -> [MatchedDataPoint] {
        guard !locations.isEmpty else { return [] }

        if hrSamples.isEmpty {
            return locations.map { MatchedDataPoint(location: $0, heartRate: nil) }
        }

        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        var result: [MatchedDataPoint] = []
        var hrIndex = 0

        for location in locations {
            while hrIndex < hrSamples.count - 1 {
                let currentDiff = abs(hrSamples[hrIndex].startDate.timeIntervalSince(location.timestamp))
                let nextDiff = abs(hrSamples[hrIndex + 1].startDate.timeIntervalSince(location.timestamp))
                if nextDiff < currentDiff {
                    hrIndex += 1
                } else {
                    break
                }
            }

            let diff = abs(hrSamples[hrIndex].startDate.timeIntervalSince(location.timestamp))
            if diff <= tolerance {
                let bpm = Int(hrSamples[hrIndex].quantity.doubleValue(for: bpmUnit))
                result.append(MatchedDataPoint(location: location, heartRate: bpm))
            } else {
                result.append(MatchedDataPoint(location: location, heartRate: nil))
            }
        }

        return result
    }
}
