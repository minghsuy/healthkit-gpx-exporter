import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@main
struct HealthKitGPXExporterApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

#if canImport(UIKit)
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // HealthKit relaunches the app in the background to deliver workout
        // updates, with no scene; the observer query must exist by the end
        // of launch or that delivery is missed.
        BackgroundSyncManager.shared.start()
        return true
    }
}
#endif
