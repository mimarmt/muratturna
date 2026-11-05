import SwiftData
import TipKit
import SwiftUI
import UIKit
import UserNotifications

@main
struct LoopnoteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(Persistence.container)
        .backgroundTask(.appRefresh(AlertScheduler.refreshTaskID)) {
            await AlertScheduler.shared.reschedule()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    private let notificationDelegate = NotificationDelegate()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Trace.log("launch \(Bundle.main.versionString)")
        Trace.startWatchdog()
        AppSettings.registerDefaults()
        if ProcessInfo.processInfo.arguments.contains("-uitest") {
            UserDefaults.standard.set(true, forKey: AppSettings.Key.onboarded)
        }
        Diagnostics.shared.start()
        UNUserNotificationCenter.current().delegate = notificationDelegate
        AlertScheduler.shared.registerCategories()
        Theme.applyNavigationBarAppearance()
        WatchSync.shared.activate()
        ProStore.shared.start()
        MeetingProcessor.shared.prewarm()
        if ProcessInfo.processInfo.arguments.contains("-uitest") { Tips.hideAllTipsForTesting() }
        // Used by CI to capture the App Review screenshot of the purchase screen.
        if ProcessInfo.processInfo.arguments.contains("-paywall") { ProStore.shared.showPaywall = true }
        try? Tips.configure([.displayFrequency(.daily)])
        return true
    }
}
