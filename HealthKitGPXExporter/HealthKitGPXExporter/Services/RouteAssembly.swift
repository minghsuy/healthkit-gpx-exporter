import Foundation

/// Joins a workout's route samples into one track. Generic over the point
/// type so it is unit-testable without CoreLocation or HealthKit.
enum RouteAssembly {
    /// Every point of every segment, in time order. HealthKit returns route
    /// samples in no promised order, and segments can interleave in time.
    static func concatenated<Point>(_ segments: [[Point]], timestamp: (Point) -> Date) -> [Point] {
        segments.joined().sorted { timestamp($0) < timestamp($1) }
    }
}
