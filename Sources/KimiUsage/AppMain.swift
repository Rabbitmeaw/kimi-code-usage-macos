import AppKit
import SwiftUI

@main
@MainActor
enum AppMain {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--check-usage") {
            Task {
                do {
                    let snapshot = try await QuotaClient().fetch()
                    print("5h used: \(snapshot.fiveHour.map { String(format: "%.1f%%", $0.usedPercent) } ?? "not provided")")
                    print("7d used: \(snapshot.sevenDay.map { String(format: "%.1f%%", $0.usedPercent) } ?? "not provided")")
                    print("updated: \(ISO8601DateFormatter().string(from: snapshot.updatedAt))")
                    exit(0)
                } catch {
                    print("usage error: \(error.localizedDescription)")
                    exit(1)
                }
            }
            RunLoop.main.run()
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if args.contains("--diagnose-overlay") || args.contains("--diagnose-stack") {
            let peers = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.yokinri.kimi-usage")
                .filter { $0.processIdentifier != getpid() }.map(\.processIdentifier))
            let kimi = Set(NSRunningApplication.runningApplications(withBundleIdentifier: KimiWindowLocator.bundleID)
                .map(\.processIdentifier))
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            for (index, window) in windows.enumerated() {
                guard let pid = window[kCGWindowOwnerPID as String] as? Int32 else { continue }
                if args.contains("--diagnose-stack") {
                    guard peers.contains(pid) || kimi.contains(pid) || pid == front else { continue }
                    let owner = peers.contains(pid) ? "overlay" : kimi.contains(pid) ? "kimi" : "foreground"
                    print("stack[\(index)] \(owner) window=\(window[kCGWindowNumber as String] ?? "?") layer=\(window[kCGWindowLayer as String] ?? "?") bounds=\(window[kCGWindowBounds as String] ?? "?")")
                    continue
                }
                guard peers.contains(pid) else { continue }
                print("overlay-window: \(window[kCGWindowNumber as String] ?? "?") layer=\(window[kCGWindowLayer as String] ?? "?") bounds=\(window[kCGWindowBounds as String] ?? "?")")
            }
            return
        }
        if args.contains("--diagnose-window") || args.contains("--diagnose-layout") {
            print("frontmost: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown")")
            if let target = KimiWindowLocator().locate() {
                print("target-window: \(target.windowID) \(target.frame)")
                let bundleURL = target.bundleURL
                let displayScale = target.screen.backingScaleFactor
                Task {
                    let measurement = await Task.detached {
                        WindowStyleReader.read(bundleURL: bundleURL, displayScale: displayScale)
                    }.value
                    print("layout: \(measurement.status)")
                    if let insets = measurement.insets {
                        print("style-header: \(insets.top), style-footer: \(insets.bottom)")
                        for corner in AttachmentCorner.allCases {
                            print("\(corner.rawValue): \(String(describing: WindowGeometry.attachmentFrame(window: target.frame, visibleScreen: target.screen.visibleFrame, corner: corner, chrome: insets)))")
                        }
                    }
                    exit(0)
                }
                RunLoop.main.run()
            } else { print("target-window: hidden (Kimi has no visible GUI window)") }
            return
        }
        if let flag = args.firstIndex(of: "--render-preview"), args.count > flag + 1 {
            Task {
                do {
                    let snapshot = try await QuotaClient().fetch()
                    renderPreview(path: args[flag + 1], snapshot: snapshot)
                    exit(0)
                } catch {
                    print("preview error: \(error.localizedDescription)")
                    exit(1)
                }
            }
            RunLoop.main.run()
            return
        }
        let controller = AppController()
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }

    private static func renderPreview(path: String, snapshot: QuotaSnapshot) {
        let store = UsageStore()
        store.corner = AttachmentCorner(rawValue: UserDefaults.standard.string(forKey: "attachmentCorner") ?? "") ?? .bottomRight
        if let data = UserDefaults.standard.data(forKey: "quotaBandSettings.v1"),
           let settings = try? JSONDecoder().decode(QuotaBandSettings.self, from: data),
           settings.validationMessage() == nil {
            store.bandSettings = settings
        }
        store.snapshot = snapshot
        let frame = CGRect(origin: .zero, size: WindowGeometry.panelSize)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let view = NSHostingView(rootView: UsageView(store: store))
        panel.contentView = view
        panel.backgroundColor = .clear
        panel.isOpaque = false
        view.frame = frame
        view.layoutSubtreeIfNeeded()
        guard let image = view.bitmapImageRepForCachingDisplay(in: frame) else { exit(1) }
        view.cacheDisplay(in: frame, to: image)
        guard let png = image.representation(using: .png, properties: [:]) else { exit(1) }
        do { try png.write(to: URL(fileURLWithPath: path)) }
        catch { print("preview error: \(error.localizedDescription)"); exit(1) }
        print("Rendered current-quota preview: \(path)")
    }
}
