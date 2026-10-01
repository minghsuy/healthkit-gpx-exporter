import Foundation

/// What a manual export does with a written file. Plain Swift so the rule
/// is unit-testable. The file is always written (the user asked for it);
/// only marking it done is conditional, under the same rule as background
/// export: the file is in iCloud Drive and the route has settled.
enum ManualExportRule {
    enum Outcome: Equatable {
        case markDone
        /// Saved on this iPhone only; stays in Export All New.
        case localOnly
        /// Exported before the route settled; background export re-exports
        /// it once settled, overwriting the same filename.
        case notSettled
    }

    static func outcome(destination: ExportDestination, settle: RouteSettle.Eligibility) -> Outcome {
        if destination == .localFallback {
            return .localOnly
        }
        return settle == .eligible ? .markDone : .notSettled
    }
}
