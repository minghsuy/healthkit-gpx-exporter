import HealthKit
import CoreLocation

class HealthKitManager {
    private let healthStore = HKHealthStore()

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitError.notAvailable
        }

        try await healthStore.requestAuthorization(toShare: [], read: Self.readTypes)
    }

    private static var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.heartRate)
        ]
        #if compiler(>=6.4)
        // Read access for the power zones in zoneGroupsByType (iOS 27).
        if #available(iOS 27, *) {
            types.insert(HKQuantityType(.cyclingPower))
        }
        #endif
        return types
    }

    func fetchCyclingWorkouts() async throws -> [HKWorkout] {
        let cyclingPredicate = HKQuery.predicateForWorkouts(with: .cycling)
        let sortDescriptor = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate,
            ascending: false
        )

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: cyclingPredicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let workouts = (samples as? [HKWorkout]) ?? []
                continuation.resume(returning: workouts)
            }
            healthStore.execute(query)
        }
    }

    /// Cycling workouts added to and deleted from HealthKit since `anchor`,
    /// plus the anchor to persist for the next call. A nil anchor returns
    /// every cycling workout.
    func fetchCyclingWorkouts(
        since anchor: HKQueryAnchor?
    ) async throws -> (workouts: [HKWorkout], deleted: [UUID], anchor: HKQueryAnchor?) {
        let cyclingPredicate = HKQuery.predicateForWorkouts(with: .cycling)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: HKObjectType.workoutType(),
                predicate: cyclingPredicate,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { _, samples, deletedObjects, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let workouts = (samples as? [HKWorkout]) ?? []
                let deleted = (deletedObjects ?? []).map(\.uuid)
                continuation.resume(returning: (workouts, deleted, newAnchor))
            }
            healthStore.execute(query)
        }
    }

    func fetchWorkout(uuid: UUID) async throws -> HKWorkout? {
        let predicate = HKQuery.predicateForObject(with: uuid)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKWorkout])?.first)
            }
            healthStore.execute(query)
        }
    }

    /// Starts a long-running observer. HealthKit calls `onUpdate` on a
    /// background queue; the handler must eventually call the completion it
    /// receives, or HealthKit backs off and, after three misses, stops
    /// background delivery.
    func observe(
        _ sampleType: HKSampleType,
        predicate: NSPredicate?,
        onUpdate: @escaping @Sendable (_ completion: @escaping HKObserverQueryCompletionHandler) -> Void
    ) -> HKObserverQuery {
        let query = HKObserverQuery(
            sampleType: sampleType,
            predicate: predicate
        ) { _, completionHandler, error in
            if error != nil {
                completionHandler()
                return
            }
            onUpdate(completionHandler)
        }
        healthStore.execute(query)
        return query
    }

    /// Needs the com.apple.developer.healthkit.background-delivery
    /// entitlement; without it this fails with errorAuthorizationDenied.
    func enableBackgroundDelivery(for type: HKObjectType) async throws {
        try await healthStore.enableBackgroundDelivery(for: type, frequency: .immediate)
    }

    /// Plain-value metadata for the GPX: the recording app and, on iOS 27,
    /// time in heart-rate and power zones.
    func metadata(for workout: HKWorkout) -> GPXWorkoutMetadata {
        let source = workout.sourceRevision.source
        var metadata = GPXWorkoutMetadata(
            source: GPXWorkoutSource(name: source.name, bundleIdentifier: source.bundleIdentifier)
        )
        #if compiler(>=6.4)
        if #available(iOS 27, *) {
            metadata.zoneSummaries = zoneSummaries(for: workout)
        }
        #endif
        return metadata
    }

    // zoneGroupsByType ships in the iOS 27 SDK (Xcode 27, Swift 6.4). Xcode
    // 26.x has Swift 6.3 and the iOS 26 SDK, so this must stay behind a
    // compiler check as well as #available.
    #if compiler(>=6.4)
    @available(iOS 27, *)
    private func zoneSummaries(for workout: HKWorkout) -> [GPXZoneSummary] {
        guard let groups = workout.zoneGroupsByType else { return [] }

        let wanted: [(type: HKQuantityType, name: String, unit: HKUnit)] = [
            (HKQuantityType(.heartRate), "heartRate", HKUnit.count().unitDivided(by: .minute())),
            (HKQuantityType(.cyclingPower), "cyclingPower", HKUnit.watt())
        ]

        return wanted.compactMap { entry in
            guard let group = groups[entry.type] else { return nil }
            let zones = group.zoneDurations.map { zoneDuration in
                GPXZoneDuration(
                    index: zoneDuration.zone.index,
                    minimum: zoneDuration.zone.minimum?.doubleValue(for: entry.unit),
                    maximum: zoneDuration.zone.maximum?.doubleValue(for: entry.unit),
                    seconds: zoneDuration.duration
                )
            }
            return GPXZoneSummary(type: entry.name, unit: entry.unit.unitString, zones: zones)
        }
    }
    #endif

    func fetchRoute(for workout: HKWorkout) async throws -> [CLLocation] {
        let routes = try await fetchWorkoutRoutes(for: workout)
        var allLocations: [CLLocation] = []

        for route in routes {
            let locations = try await fetchLocations(for: route)
            allLocations.append(contentsOf: locations)
        }

        return allLocations.sorted { $0.timestamp < $1.timestamp }
    }

    private func fetchWorkoutRoutes(for workout: HKWorkout) async throws -> [HKWorkoutRoute] {
        let routePredicate = HKQuery.predicateForObjects(from: workout)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: HKSeriesType.workoutRoute(),
                predicate: routePredicate,
                anchor: nil,
                limit: HKObjectQueryNoLimit
            ) { _, samples, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let routes = (samples as? [HKWorkoutRoute]) ?? []
                continuation.resume(returning: routes)
            }
            healthStore.execute(query)
        }
    }

    private func fetchLocations(for route: HKWorkoutRoute) async throws -> [CLLocation] {
        try await withCheckedThrowingContinuation { continuation in
            var allLocations: [CLLocation] = []
            var resumed = false

            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error {
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: error)
                    }
                    return
                }

                if let locations {
                    allLocations.append(contentsOf: locations)
                }

                if done && !resumed {
                    resumed = true
                    continuation.resume(returning: allLocations)
                }
            }
            healthStore.execute(query)
        }
    }

    func fetchHeartRateSamples(for workout: HKWorkout) async throws -> [HKQuantitySample] {
        let heartRateType = HKQuantityType(.heartRate)
        let predicate = HKQuery.predicateForSamples(
            withStart: workout.startDate,
            end: workout.endDate,
            options: .strictStartDate
        )
        let sortDescriptor = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate,
            ascending: true
        )

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: heartRateType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let hrSamples = (samples as? [HKQuantitySample]) ?? []
                continuation.resume(returning: hrSamples)
            }
            healthStore.execute(query)
        }
    }

    func fetchAverageHeartRate(for workout: HKWorkout) async throws -> Int? {
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            return nil
        }

        let predicate = HKQuery.predicateForObjects(from: workout)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: heartRateType,
                quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { _, statistics, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let bpmUnit = HKUnit.count().unitDivided(by: .minute())
                if let average = statistics?.averageQuantity() {
                    continuation.resume(returning: Int(average.doubleValue(for: bpmUnit)))
                } else {
                    continuation.resume(returning: nil)
                }
            }
            healthStore.execute(query)
        }
    }
}

enum HealthKitError: LocalizedError {
    case notAvailable

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "HealthKit is not available on this device."
        }
    }
}
