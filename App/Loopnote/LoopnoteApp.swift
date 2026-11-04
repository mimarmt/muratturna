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
        AppSettings.registerDefaults()
        UNUserNotificationCenter.current().delegate = notificationDelegate
        AlertScheduler.shared.registerCategories()
        Theme.applyNavigationBarAppearance()
        WatchSync.shared.activate()
        ProStore.shared.start()
        try? Tips.configure([.displayFrequency(.daily)])
        return true
    }
}
