import AppKit
import CoreGraphics

@MainActor
struct KimiWindowLocator {
    static let bundleID = "com.kimi.code.desktop"

    struct Target {
        let processID: pid_t
        let bundleURL: URL
        let windowID: CGWindowID
        let screenBounds: CGRect
        let frame: CGRect
        let screen: NSScreen
        let orderedWindowIDs: [CGWindowID]
    }

    func locate() -> Target? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
                .first(where: { !$0.isHidden && !$0.isTerminated }),
              let bundleURL = app.bundleURL,
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
              ) as? [[String: Any]] else { return nil }

        // The system list is front-to-back: follow the foremost regular Kimi window.
        for entry in windows {
            guard let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let alpha = entry[kCGWindowAlpha as String] as? Double,
                  let raw = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary),
                  WindowGeometry.isTargetWindow(pid: pid, targetPID: app.processIdentifier,
                                                layer: layer, alpha: alpha, bounds: bounds),
                  let id = entry[kCGWindowNumber as String] as? UInt32,
                  let screen = matchingScreen(bounds) else { continue }
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                ?? CGMainDisplayID()
            return Target(processID: app.processIdentifier, bundleURL: bundleURL, windowID: id, screenBounds: bounds,
                          frame: WindowGeometry.appKitFrame(bounds,
                              displayBounds: CGDisplayBounds(displayID), screenFrame: screen.frame),
                          screen: screen,
                          orderedWindowIDs: windows.compactMap { $0[kCGWindowNumber as String] as? UInt32 })
        }
        return nil
    }

    private func matchingScreen(_ bounds: CGRect) -> NSScreen? {
        NSScreen.screens.max { a, b in overlap(bounds, a) < overlap(bounds, b) }
    }

    private func overlap(_ bounds: CGRect, _ screen: NSScreen) -> CGFloat {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return 0 }
        let intersection = bounds.intersection(CGDisplayBounds(id.uint32Value))
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}
