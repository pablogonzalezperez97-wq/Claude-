import SwiftUI
import BackgroundTasks
import UserNotifications

@main
struct JARVISApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var backend = Backend.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                if backend.signedIn { RootView() } else { SignInView() }
            }
            .environmentObject(backend)
            .preferredColorScheme(.dark)
            .tint(Theme.gold)
        }
        .onChange(of: phase) { _, p in
            guard p == .active, backend.signedIn else { return }
            Task {
                await HealthSync.shared.syncAndUpload(days: 3)
            }
        }
        .backgroundTask(.appRefresh(AppDelegate.refreshID)) {
            await HealthSync.shared.syncAndUpload(days: 2)
            await AppDelegate.scheduleRefresh()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let refreshID = "es.jarvis.refresh"

    func application(_ app: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task {
            // los permisos se piden una vez; después, iOS despierta la app con datos nuevos
            try? await HealthSync.shared.authorize()
            await HealthSync.shared.enableBackgroundDelivery()
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if granted { await MainActor.run { app.registerForRemoteNotifications() } }
            await Self.scheduleRefresh()
        }
        return true
    }

    func application(_: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        Task { await Backend.shared.registerDevice(token: hex) }
    }

    // mostrar las alertas de los agentes también con la app abierta
    func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification) async -> UNNotificationPresentationOptions {
        Task { await Backend.shared.refreshToday() }
        return [.banner, .sound]
    }

    static func scheduleRefresh() async {
        let req = BGAppRefreshTaskRequest(identifier: refreshID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 3600)
        try? BGTaskScheduler.shared.submit(req)
    }
}

enum Theme {
    static let gold = Color(red: 0.79, green: 0.64, blue: 0.42)
    static let panel = Color(white: 0.09)
    static let line = Color(white: 0.18)

    static func color(_ light: Today.Light) -> Color {
        switch light {
        case .green: return .green
        case .amber: return .orange
        case .red: return .red
        case .unknown: return .gray
        }
    }
}
