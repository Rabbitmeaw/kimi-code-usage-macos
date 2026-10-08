import AppKit

@main
@MainActor
enum WatcherMain {
    static func main() {
        let arguments = CommandLine.arguments
        guard let option = arguments.firstIndex(of: "--app-path"), option + 1 < arguments.count else {
            fputs("Usage: KimiUsageWatcher --app-path PATH\n", stderr)
            exit(64)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let watcher = KimiLaunchWatcher(appURL: URL(fileURLWithPath: arguments[option + 1], isDirectory: true))
        watcher.start()
        withExtendedLifetime(watcher) { RunLoop.main.run() }
    }
}

@MainActor
private final class KimiLaunchWatcher: NSObject {
    private static let kimiBundleID = "com.kimi.code.desktop"
    private static let mainBundleID = "com.yokinri.kimi-usage"
    private let appURL: URL
    private var opening = false

    init(appURL: URL) {
        self.appURL = appURL
        super.init()
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(applicationChanged(_:)),
                           name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationChanged(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        openMainAppIfNeeded()
    }

    @objc private func applicationChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == Self.kimiBundleID else { return }
        // The main app handles Kimi termination; this watcher waits for the next launch.
        if notification.name == NSWorkspace.didLaunchApplicationNotification {
            openMainAppIfNeeded()
        }
    }

    private var followsKimi: Bool {
        guard let data = UserDefaults(suiteName: Self.mainBundleID)?.data(forKey: "quotaBandSettings.v1"),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return true }
        return settings["followsKimi"] as? Bool ?? true
    }

    private func openMainAppIfNeeded() {
        guard !opening, followsKimi,
              NSRunningApplication.runningApplications(withBundleIdentifier: Self.kimiBundleID)
                .contains(where: { !$0.isTerminated }),
              !NSRunningApplication.runningApplications(withBundleIdentifier: Self.mainBundleID)
                .contains(where: { !$0.isTerminated }) else { return }
        opening = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--follow-launch"]
        configuration.activates = false
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { [weak self] _, error in
            if let error {
                NSLog("Kimi Usage watcher could not open the app: %@", error.localizedDescription)
            }
            Task { @MainActor [weak self] in self?.opening = false }
        }
    }
}
