import Foundation
import CoreGraphics

@main
struct CoreChecks {
    static func main() async throws {
        let checks: [(String, () throws -> Void)] = [
            ("Desktop usage schema and update time", desktopUsage),
            ("Missing weekly window and zero percent", missingWeeklyWindow),
            ("Weekly-only window and full quota", weeklyOnlyWindow),
            ("Invalid quota ratios", invalidRatios),
            ("Unavailable usage stays unavailable", emptyUsage),
            ("Sanitized authorization errors", authorizationError),
            ("Expired login without HTTP status", expiredLogin),
            ("Error envelopes and malformed data", errorEnvelopes),
            ("Loopback host and port filtering", loopbackFiltering),
            ("Coordinate conversion across displays", coordinateConversion),
            ("Four attachment corners and clipping", attachmentCorners),
            ("Installed style variables and version changes", styleInsets),
            ("Target window filtering", windowFiltering),
            ("Default quota bands", defaultQuotaBands),
            ("Quota palettes for three to six bands", quotaBandColors),
            ("Invalid quota band settings", invalidQuotaBands),
            ("Quota band boundary selection", quotaBandBoundaries),
            ("Qualified emoji sequences", validEmoji),
            ("Reject text and invalid emoji sequences", invalidEmoji),
            ("Quota settings JSON round trip", quotaSettingsRoundTrip),
            ("Missing and invalid quota reset time", invalidQuotaResetTime),
            ("Quota reset time rounds up to minutes", quotaResetMinutes),
            ("Quota reset hour and day formatting", quotaResetHourDays),
            ("Legacy display settings migration", legacyDisplaySettings),
            ("Display colors opacity and gradient round trip", displaySettingsRoundTrip),
            ("Invalid display color and opacity values", invalidDisplaySettings),
            ("Follow Kimi defaults migration and persistence", followsKimiSettings)
        ]
        for (name, check) in checks {
            try check()
            print("PASS \(name)")
        }
        let cacheChecks: [(String, () async throws -> Void)] = [
            ("Unchanged style resources reuse the cached parse", styleCacheHit),
            ("Stylesheet metadata changes invalidate the cache", styleCacheCSSChanges),
            ("HTML stylesheet references invalidate the cache", styleCacheReferences),
            ("Display scale and bundle changes invalidate the cache", styleCacheScaleAndBundle),
            ("Missing style resources recover without caching failure", styleCacheMissingResource),
            ("Unrecognized styles remain retryable", styleCacheParseFailure)
        ]
        for (name, check) in cacheChecks {
            try await check()
            print("PASS \(name)")
        }
        print("\(checks.count + cacheChecks.count) core checks passed")
    }

    private static func desktopUsage() throws {
        let updatedAt = Date(timeIntervalSince1970: 1234)
        let snapshot = try QuotaClient.parse(Data("""
        {"code":0,"data":{"kind":"ok","quota":{"usages":{
          "limit5h":{"usedRatio":0.17177,"resetAt":"2026-10-08T06:53:24Z"},
          "limit7d":{"usedRatio":0.28977,"resetAt":"2026-10-13T06:53:24.123Z"}
        },"extraUsage":null}}}
        """.utf8), updatedAt: updatedAt)
        try require(abs((snapshot.fiveHour?.usedPercent ?? -1) - 17.177) < 0.0001, "5h percentage")
        try require(abs((snapshot.sevenDay?.usedPercent ?? -1) - 28.977) < 0.0001, "7d percentage")
        try require(snapshot.fiveHour?.resetAt == ISO8601DateFormatter().date(from: "2026-10-08T06:53:24Z"), "5h reset timestamp")
        try require(snapshot.sevenDay?.resetAt != nil, "7d fractional-second reset timestamp")
        try require(snapshot.updatedAt == updatedAt, "Receipt timestamp")
    }

    private static func missingWeeklyWindow() throws {
        let snapshot = try parseUsages(#""limit5h":{"usedRatio":0}"#)
        try require(snapshot.fiveHour?.usedPercent == 0, "Real zero quota reading")
        try require(snapshot.sevenDay == nil, "Missing 7d must remain unavailable")
    }

    private static func weeklyOnlyWindow() throws {
        let snapshot = try parseUsages(#""limit7d":{"usedRatio":"1"}"#)
        try require(snapshot.fiveHour == nil, "Missing 5h must remain unavailable")
        try require(snapshot.sevenDay?.usedPercent == 100, "Numeric-string full quota reading")
    }

    private static func invalidRatios() throws {
        for ratio in ["-0.1", "1.1", "true", "false", "null", #""NaN""#, #""infinity""#, #""not-a-ratio""#] {
            try expectQuotaError(.invalidResponse, label: "Reject ratio \(ratio)") {
                try parseUsages("\"limit5h\":{\"usedRatio\":\(ratio)}")
            }
        }
    }

    private static func emptyUsage() throws {
        try expectQuotaError(.noUsage, label: "Empty usage is not zero quota") { try parseUsages("") }
    }

    private static func authorizationError() throws {
        let data = Data(#"{"code":0,"data":{"kind":"error","status":401,"message":"private upstream response"}}"#.utf8)
        try expectQuotaError(.loginRequired, label: "Authorization error") { try QuotaClient.parse(data) }
        try require(!QuotaClientError.loginRequired.localizedDescription.contains("private"), "Upstream message stays private")
    }

    private static func expiredLogin() throws {
        let data = Data(#"{"code":0,"data":{"kind":"error","message":"Please login again"}}"#.utf8)
        try expectQuotaError(.loginRequired, label: "Expired login without status") { try QuotaClient.parse(data) }
    }

    private static func errorEnvelopes() throws {
        for (payload, expected) in [
            (#"{"code":40112,"msg":"private response","data":null}"#, QuotaClientError.loginRequired),
            (#"{"code":50000,"msg":"private response","data":null}"#, QuotaClientError.usageUnavailable),
            (#"{"code":0,"data":{"kind":"error","status":503,"message":"private response"}}"#, QuotaClientError.usageUnavailable),
            (#"{"code":0,"data":{"kind":"unexpected"}}"#, QuotaClientError.invalidResponse),
            (#"{"data":{}}"#, QuotaClientError.invalidResponse)
        ] {
            try expectQuotaError(expected, label: "Reject unsuccessful or malformed envelope") {
                try QuotaClient.parse(Data(payload.utf8))
            }
        }
    }

    private static func loopbackFiltering() throws {
        for host in ["127.0.0.1", "localhost", "LOCALHOST", "::1"] {
            let url = QuotaClient.serverURL(host: host, port: 54897)
            try require(url != nil, "Allow loopback \(host)")
            try require(url?.path == "/api/v1/oauth/usage", "Official local usage path")
            try require(url?.port == 54897, "Preserve local server port")
        }
        for host in ["0.0.0.0", "192.168.1.2", "example.com", "localhost.example.com", "127.0.0.1@evil.example", "http://localhost", "[::1]", ""] {
            try require(QuotaClient.serverURL(host: host, port: 54897) == nil, "Reject host \(host)")
        }
        for port in [-1, 0, 65536] {
            try require(QuotaClient.serverURL(host: "localhost", port: port) == nil, "Reject port \(port)")
        }
    }

    private static func coordinateConversion() throws {
        try require(WindowGeometry.appKitFrame(CGRect(x: -1800, y: 100, width: 900, height: 600),
            displayBounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            screenFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
            == CGRect(x: -1800, y: 380, width: 900, height: 600), "Left display with negative X")
        try require(WindowGeometry.appKitFrame(CGRect(x: 20, y: -1000, width: 900, height: 600),
            displayBounds: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
            screenFrame: CGRect(x: 0, y: 1080, width: 1920, height: 1080))
            == CGRect(x: 20, y: 1480, width: 900, height: 600), "Upper display Y conversion")
        try require(WindowGeometry.appKitFrame(CGRect(x: 20, y: 1180, width: 900, height: 600),
            displayBounds: CGRect(x: 0, y: 1080, width: 1920, height: 1080),
            screenFrame: CGRect(x: 0, y: -1080, width: 1920, height: 1080))
            == CGRect(x: 20, y: -700, width: 900, height: 600), "Lower display with negative AppKit Y")
    }

    private static func attachmentCorners() throws {
        let screen = CGRect(x: 0, y: 24, width: 1440, height: 876)
        let window = CGRect(x: 200, y: 100, width: 1000, height: 700)
        let insets = WindowChromeInsets(top: 48, bottom: 56)
        let expected: [AttachmentCorner: CGRect] = [
            .topLeft: CGRect(x: 214, y: 631, width: 203, height: 117),
            .topRight: CGRect(x: 983, y: 631, width: 203, height: 117),
            .bottomLeft: CGRect(x: 214, y: 160, width: 203, height: 117),
            .bottomRight: CGRect(x: 983, y: 160, width: 203, height: 117)
        ]
        let fixedCorners: [AttachmentCorner] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        for corner in fixedCorners {
            guard let card = WindowGeometry.attachmentFrame(window: window, visibleScreen: screen, corner: corner, chrome: insets) else {
                throw CheckFailure("Missing attachment for \(corner.rawValue)")
            }
            try require(card == expected[corner], "Exact corner placement \(corner.rawValue)")
            try require(window.contains(card) && screen.contains(card), "Corner stays inside window and screen")
            try require(card.size == WindowGeometry.panelSize, "Card size")
        }
        try require(WindowGeometry.attachmentFrame(window: window, visibleScreen: screen, corner: .free, chrome: insets) == nil,
                    "Free mode does not compute an attached frame")
        let tallerBars = WindowChromeInsets(top: 72, bottom: 84)
        let movedTop = WindowGeometry.attachmentFrame(window: window, visibleScreen: screen, corner: .topRight, chrome: tallerBars)
        let movedBottom = WindowGeometry.attachmentFrame(window: window, visibleScreen: screen, corner: .bottomRight, chrome: tallerBars)
        try require(movedTop?.maxY == 724, "Top follows actual header height")
        try require(movedBottom?.minY == 188, "Bottom follows actual footer height")
        let partiallyOffscreen = CGRect(x: 1300, y: 100, width: 800, height: 600)
        try require(WindowGeometry.attachmentFrame(window: partiallyOffscreen, visibleScreen: screen, corner: .bottomRight, chrome: insets) == nil, "Hide when visible portion is too narrow")
        try require(WindowGeometry.attachmentFrame(window: CGRect(x: 0, y: 0, width: 100, height: 100), visibleScreen: screen, corner: .bottomRight, chrome: insets) == nil, "Hide on undersized windows")
    }

    private static let styleFixtureCSS = """
        :root { --panel-head-h:48px; --space-2:8px; --p-hairline:.5px; --icon-button-sm:26px; --base-font:14px; --ui-shift:calc(var(--base-font,14px) - 14px); --ui-b2:calc(14px + var(--ui-shift)); --ui-font-size:var(--ui-b2); --ui-font-size-sm:calc(var(--ui-font-size) - 1px); --leading-tight:1.25; }
        @media(max-resolution:1.1dppx) { :root { --p-hairline:1px; } }
        .chat-header[data-v-test] { height:var(--panel-head-h,48px); }
        .side-footer[data-v-test] { display:flex; padding:var(--space-2) 8px; border-top:var(--p-hairline) solid black; }
        .user-menu-trigger[data-v-test] { display:flex; padding:8px 8px; font-size:var(--ui-font-size-sm); line-height:var(--leading-tight); }
        .user-menu-avatar[data-v-test] { height:24px; }
        .ui-badge--sm[data-v-test] { height:18px; }
        .ui-icon-button--sm[data-v-test] { height:var(--icon-button-sm); }
        """

    private static func styleInsets() throws {
        let css = styleFixtureCSS
        let retina = WindowStyleReader.parse(css: css, displayScale: 2)
        try require(retina?.top == 48 && retina?.bottom == 56.5, "Resolve installed-style variables and footer box")
        let standard = WindowStyleReader.parse(css: css, displayScale: 1)
        try require(standard?.bottom == 57, "Apply display-specific hairline rule")
        let updated = css.replacingOccurrences(of: "--panel-head-h:48px", with: "--panel-head-h:60px")
            .replacingOccurrences(of: "--space-2:8px", with: "--space-2:10px")
        let changed = WindowStyleReader.parse(css: updated)
        try require(changed?.top == 60 && changed?.bottom == 60.5, "Stylesheet changes must change computed heights")
        try require(WindowStyleReader.parse(css: ":root{--panel-head-h:48px}") == nil, "Missing layout rules must not fall back to hardcoded heights")
    }

    private static func styleCacheHit() async throws {
        let bundle = try makeStyleBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let cache = WindowStyleReaderCache()
        let first = await cache.read(bundleURL: bundle)
        let equivalent = URL(fileURLWithPath: bundle.path + "/Contents/..", isDirectory: true)
        let second = await cache.read(bundleURL: equivalent)
        try require(first.insets?.top == 48 && second.insets?.bottom == 56.5, "Cached layout preserves measured insets")
        let count = await cache.parseCount
        try require(count == 1, "Unchanged resources and standardized bundle path must not parse again")
    }

    private static func styleCacheCSSChanges() async throws {
        let bundle = try makeStyleBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let cache = WindowStyleReaderCache()
        _ = await cache.read(bundleURL: bundle)
        let file = styleDirectory(bundle).appendingPathComponent("assets/main.css")
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        let changed = styleFixtureCSS.replacingOccurrences(of: "--panel-head-h:48px", with: "--panel-head-h:60px")
        try changed.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let byDate = await cache.read(bundleURL: bundle)
        try require(byDate.insets?.top == 60, "Same-size CSS changes are detected by modification date")
        let larger = changed.replacingOccurrences(of: "--panel-head-h:60px", with: "--panel-head-h:100px")
        try larger.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let bySize = await cache.read(bundleURL: bundle)
        try require(bySize.insets?.top == 100, "CSS size changes are detected even with an unchanged modification date")
        let count = await cache.parseCount
        try require(count == 3, "Each changed stylesheet is parsed exactly once")
    }

    private static func styleCacheReferences() async throws {
        let bundle = try makeStyleBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let cache = WindowStyleReaderCache()
        _ = await cache.read(bundleURL: bundle)
        let directory = styleDirectory(bundle)
        let updated = styleFixtureCSS.replacingOccurrences(of: "--panel-head-h:48px", with: "--panel-head-h:72px")
        try updated.write(to: directory.appendingPathComponent("assets/next.css"), atomically: true, encoding: .utf8)
        let html = #"<link rel="stylesheet" href="/assets/next.css">"#
        let index = directory.appendingPathComponent("index.html")
        try html.write(to: index, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)],
                                             ofItemAtPath: index.path)
        let measurement = await cache.read(bundleURL: bundle)
        try require(measurement.insets?.top == 72, "Changed index references load the new stylesheet")
        let count = await cache.parseCount
        try require(count == 2, "Changing HTML references invalidates the previous source list")
    }

    private static func styleCacheScaleAndBundle() async throws {
        let bundle = try makeStyleBundle()
        let other = try makeStyleBundle(css: styleFixtureCSS.replacingOccurrences(of: "--panel-head-h:48px", with: "--panel-head-h:64px"))
        defer {
            try? FileManager.default.removeItem(at: bundle)
            try? FileManager.default.removeItem(at: other)
        }
        let cache = WindowStyleReaderCache()
        let retina = await cache.read(bundleURL: bundle, displayScale: 2)
        let standard = await cache.read(bundleURL: bundle, displayScale: 1)
        try require(retina.insets?.bottom == 56.5 && standard.insets?.bottom == 57,
                    "Display scale invalidates the parsed media-query result")
        let nextBundle = await cache.read(bundleURL: other, displayScale: 1)
        try require(nextBundle.insets?.top == 64, "Another bundle cannot reuse the previous insets")
        _ = await cache.read(bundleURL: bundle, displayScale: 1)
        let count = await cache.parseCount
        try require(count == 4, "Only the most recent successful result is retained")
    }

    private static func styleCacheMissingResource() async throws {
        let bundle = try makeStyleBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let cache = WindowStyleReaderCache()
        _ = await cache.read(bundleURL: bundle)
        let file = styleDirectory(bundle).appendingPathComponent("assets/main.css")
        try FileManager.default.removeItem(at: file)
        for _ in 0..<2 {
            let missing = await cache.read(bundleURL: bundle)
            try require(missing.insets == nil && missing.status == "暂时无法读取 Kimi 安装样式",
                        "A missing stylesheet must return the existing read error instead of stale cached insets")
        }
        let updated = styleFixtureCSS.replacingOccurrences(of: "--panel-head-h:48px", with: "--panel-head-h:62px")
        try updated.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)],
                                             ofItemAtPath: file.path)
        let recovered = await cache.read(bundleURL: bundle)
        try require(recovered.insets?.top == 62, "Restoring the stylesheet retries and computes the current layout")
        let count = await cache.parseCount
        try require(count == 2, "Missing files do not parse or replace the successful cache entry")
    }

    private static func styleCacheParseFailure() async throws {
        let bundle = try makeStyleBundle(css: ":root{--panel-head-h:48px}")
        defer { try? FileManager.default.removeItem(at: bundle) }
        let cache = WindowStyleReaderCache()
        for _ in 0..<2 {
            let failed = await cache.read(bundleURL: bundle)
            try require(failed.insets == nil && failed.status == "尚未识别 Kimi 窗口样式栏高",
                        "Unsupported CSS retains the existing parse error")
        }
        let attempts = await cache.parseCount
        try require(attempts == 2, "A failed parse must not be cached")
        let file = styleDirectory(bundle).appendingPathComponent("assets/main.css")
        try styleFixtureCSS.write(to: file, atomically: true, encoding: .utf8)
        let recovered = await cache.read(bundleURL: bundle)
        try require(recovered.insets?.top == 48, "A corrected stylesheet recovers after a failed parse")
    }

    private static func styleDirectory(_ bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/Resources/desktop-dist", isDirectory: true)
    }

    private static func makeStyleBundle(css: String = styleFixtureCSS) throws -> URL {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("KimiStyleChecks-" + UUID().uuidString + ".app",
                                                                                 isDirectory: true)
        let directory = styleDirectory(bundle)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try #"<link rel="stylesheet" href="/assets/main.css">"#.write(to: directory.appendingPathComponent("index.html"),
                                                                    atomically: true, encoding: .utf8)
        try css.write(to: directory.appendingPathComponent("assets/main.css"), atomically: true, encoding: .utf8)
        return bundle
    }

    private static func windowFiltering() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
        try require(WindowGeometry.isTargetWindow(pid: 42, targetPID: 42, layer: 0, alpha: 1, bounds: bounds), "Allow target GUI window")
        try require(!WindowGeometry.isTargetWindow(pid: 99, targetPID: 42, layer: 0, alpha: 1, bounds: bounds), "Reject another app")
        try require(!WindowGeometry.isTargetWindow(pid: 42, targetPID: 42, layer: 3, alpha: 1, bounds: bounds), "Reject utility layer")
        try require(!WindowGeometry.isTargetWindow(pid: 42, targetPID: 42, layer: 0, alpha: 0, bounds: bounds), "Reject invisible window")
        try require(!WindowGeometry.isTargetWindow(pid: 42, targetPID: 42, layer: 0, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 100, height: 100)), "Reject undersized window")
        try require(!WindowGeometry.isTargetWindow(pid: 42, targetPID: 42, layer: 0, alpha: 1, bounds: CGRect(x: CGFloat.infinity, y: 0, width: 1000, height: 700)), "Reject non-finite coordinates")
    }

    private static func defaultQuotaBands() throws {
        let settings = QuotaBandSettings.defaults
        try require(settings.bands.map(\.lowerBound) == [0, 1, 20, 40, 70], "Default thresholds are ordered from low to high")
        try require(settings.bands.map(\.emoji) == ["😇", "🤦‍♀️", "🧘", "🏂🏻", "🪂"], "Preserve the five user emoji")
        try require(settings.validationMessage() == nil, "Defaults pass validation")
    }

    private static func quotaBandColors() throws {
        let expected: [Int: [QuotaBandColor]] = [
            3: [.red, .yellow, .green],
            4: [.red, .orange, .yellow, .green],
            5: [.red, .orange, .yellow, .green, .blue],
            6: [.red, .orange, .yellow, .green, .blue, .purple]
        ]
        for count in 3...6 {
            try require(QuotaBandSettings.colors(for: count) == expected[count], "Palette for \(count) bands")
            let settings = QuotaBandSettings(bands: (0..<count).map { QuotaBand(lowerBound: Double($0 * 10), emoji: "😇") })
            try require(settings.validationMessage() == nil, "Allow \(count) bands")
            try require(settings.appearance(remaining: 100).color == expected[count]?.last, "Highest band uses last palette color")
        }
    }

    private static func invalidQuotaBands() throws {
        for count in [0, 1, 2, 7] {
            let settings = QuotaBandSettings(bands: (0..<count).map { QuotaBand(lowerBound: Double($0 * 10), emoji: "😇") })
            try require(settings.validationMessage() != nil, "Reject \(count) bands")
        }
        let invalidBounds: [[Double]] = [[1, 20, 40], [0, 20, 20], [0, 40, 20], [0, -1, 40],
                                        [0, 20, 101], [0, .nan, 40], [0, 20, .infinity], [0, -.infinity, 40]]
        for lowerBounds in invalidBounds {
            let settings = QuotaBandSettings(bands: lowerBounds.map { QuotaBand(lowerBound: $0, emoji: "😇") })
            try require(settings.validationMessage() != nil, "Reject nonzero first, unordered, out-of-range or nonfinite bounds")
        }
        for emoji in ["", "ABC", "😇🪂", "🏻", "😀\u{200D}😀"] {
            var settings = QuotaBandSettings.defaults
            settings.bands[2].emoji = emoji
            try require(settings.validationMessage() != nil, "Reject invalid band emoji")
        }
    }

    private static func quotaBandBoundaries() throws {
        let settings = QuotaBandSettings.defaults
        let expected: [(Double, String, QuotaBandColor)] = [
            (0, "😇", .red), (0.999, "😇", .red), (1, "🤦‍♀️", .orange),
            (19.999, "🤦‍♀️", .orange), (20, "🧘", .yellow),
            (39.999, "🧘", .yellow), (40, "🏂🏻", .green),
            (69.999, "🏂🏻", .green), (70, "🪂", .blue), (100, "🪂", .blue)
        ]
        for (remaining, emoji, color) in expected {
            let result = settings.appearance(remaining: remaining)
            try require(result.emoji == emoji && result.color == color, "Inclusive threshold at \(remaining)%")
        }
        let fullOnly = QuotaBandSettings(bands: [
            QuotaBand(lowerBound: 0, emoji: "😇"), QuotaBand(lowerBound: 50, emoji: "🧘"),
            QuotaBand(lowerBound: 100, emoji: "🪂")
        ])
        try require(fullOnly.validationMessage() == nil, "Allow an upper threshold of 100")
        try require(fullOnly.appearance(remaining: 99.999).emoji == "🧘", "Below 100 stays in preceding band")
        try require(fullOnly.appearance(remaining: 100).emoji == "🪂", "Exactly 100 selects full-only band")
    }

    private static func validEmoji() throws {
        for value in ["😇", "🤦‍♀️", "🧘", "🏂🏻", "🪂", "👩🏽‍💻", "🤦‍♀", "🏳️‍🌈", "❤️",
                      "🇨🇳", "1️⃣", "#️⃣", "🫪", "🏴\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}"] {
            try require(EmojiInput.isSingleEmoji(value), "Accept qualified single emoji \(value)")
        }
    }

    private static func invalidEmoji() throws {
        for value in ["", " ", "A", "中文", "1", "123", "#", "*", "😇🪂", "😇 text", " 😇", "😇\n",
                      "🏻", "\u{200D}", "\u{FE0F}", "🇦", "🇿🇿", "😀\u{200D}😀", "😇\u{200D}💻",
                      "👩\u{200D}A", "1\u{FE0F}", "A\u{FE0F}", "1\u{20E3}", "❤", "🏳‍🌈"] {
            try require(!EmojiInput.isSingleEmoji(value), "Reject text, components and unsupported emoji sequence")
        }
    }

    private static func quotaSettingsRoundTrip() throws {
        let custom = QuotaBandSettings(bands: [
            QuotaBand(lowerBound: 0, emoji: "😇"), QuotaBand(lowerBound: 0.5, emoji: "🤦‍♀️"),
            QuotaBand(lowerBound: 20, emoji: "🧘"), QuotaBand(lowerBound: 40, emoji: "🏂🏻"),
            QuotaBand(lowerBound: 70, emoji: "🪂"), QuotaBand(lowerBound: 100, emoji: "🇨🇳")
        ])
        for settings in [QuotaBandSettings.defaults, custom] {
            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(QuotaBandSettings.self, from: data)
            try require(decoded == settings, "Persist exact thresholds and composite emoji")
            try require(decoded.validationMessage() == nil, "Persisted settings still validate")
            try require(decoded.appearance(remaining: 100).color == settings.appearance(remaining: 100).color,
                        "Restored band count preserves automatic colors")
        }
    }

    private static func legacyDisplaySettings() throws {
        let data = Data(#"{"bands":[{"lowerBound":0,"emoji":"😇"},{"lowerBound":32.5,"emoji":"🧘"},{"lowerBound":100,"emoji":"🪂"}]}"#.utf8)
        let settings = try JSONDecoder().decode(QuotaBandSettings.self, from: data)
        try require(settings.bands.map(\.lowerBound) == [0, 32.5, 100], "Migration preserves user thresholds and band count")
        try require(settings.bands.map(\.emoji) == ["😇", "🧘", "🪂"], "Migration preserves user emoji")
        try require(settings.bands.allSatisfy { $0.customColor == nil }, "Legacy bands retain automatic colors")
        try require(settings.backgroundColor == .black, "Legacy background defaults to black")
        try require(settings.backgroundOpacity == 0.5, "Legacy background defaults to half opacity")
        try require(!settings.usesGradient, "Legacy gradients default off")
        try require(settings.followsKimi, "Legacy band-only settings follow Kimi by default")
        try require(settings.validationMessage() == nil, "Migrated settings validate")
        try require(settings.appearance(remaining: 100).color == .green, "Migration preserves the three-band palette")
        let restored = try JSONDecoder().decode(QuotaBandSettings.self, from: JSONEncoder().encode(settings))
        try require(restored == settings, "Migrated settings persist with the new fields")
    }

    private static func displaySettingsRoundTrip() throws {
        let customColor = DisplayColor(red: 0, green: 1, blue: 0.25)
        for opacity in [0.0, 0.5, 1.0] {
            for gradient in [false, true] {
                var settings = QuotaBandSettings.defaults
                settings.backgroundColor = DisplayColor(red: 0.75, green: 0.125, blue: 1)
                settings.backgroundOpacity = opacity
                settings.usesGradient = gradient
                settings.bands[2].customColor = customColor
                try require(settings.validationMessage() == nil, "Allow endpoint colors and opacity")
                let restored = try JSONDecoder().decode(QuotaBandSettings.self, from: JSONEncoder().encode(settings))
                try require(restored == settings, "Persist background, opacity, gradient and band custom color")
                let selected = restored.appearance(remaining: 20)
                try require(selected.emoji == "🧘" && selected.color == .yellow && selected.customColor == customColor,
                            "Appearance returns selected custom color without changing palette semantics")
                try require(restored.appearance(remaining: 19.999).customColor == nil,
                            "Other bands keep their automatic color")
            }
        }
    }

    private static func followsKimiSettings() throws {
        try require(QuotaBandSettings.defaults.followsKimi, "Default settings follow Kimi")
        let implicit = QuotaBandSettings(bands: QuotaBandSettings.defaults.bands)
        try require(implicit.followsKimi, "Initializer follows Kimi unless explicitly disabled")

        let legacy = Data(#"{"bands":[{"lowerBound":0,"emoji":"😇"},{"lowerBound":33.5,"emoji":"🏂🏻","customColor":{"red":0.3,"green":0.6,"blue":0.9}},{"lowerBound":80,"emoji":"🪂"}],"backgroundColor":{"red":0.125,"green":0.25,"blue":0.5},"backgroundOpacity":0.35,"usesGradient":true}"#.utf8)
        let customColor = DisplayColor(red: 0.3, green: 0.6, blue: 0.9)
        let expected = QuotaBandSettings(bands: [
            QuotaBand(lowerBound: 0, emoji: "😇"),
            QuotaBand(lowerBound: 33.5, emoji: "🏂🏻", customColor: customColor),
            QuotaBand(lowerBound: 80, emoji: "🪂")
        ], backgroundColor: DisplayColor(red: 0.125, green: 0.25, blue: 0.5),
           backgroundOpacity: 0.35, usesGradient: true)
        let migrated = try JSONDecoder().decode(QuotaBandSettings.self, from: legacy)
        try require(migrated == expected && migrated.followsKimi,
                    "Legacy display JSON defaults follow on without changing bands or appearance")

        for follows in [true, false] {
            let settings = QuotaBandSettings(bands: migrated.bands, backgroundColor: migrated.backgroundColor,
                                            backgroundOpacity: migrated.backgroundOpacity,
                                            usesGradient: migrated.usesGradient, followsKimi: follows)
            let encoded = try JSONEncoder().encode(settings)
            let restored = try JSONDecoder().decode(QuotaBandSettings.self, from: encoded)
            try require(restored.followsKimi == follows && restored == settings,
                        "Follow setting persists both enabled and disabled with existing display settings")
            try require(restored.validationMessage() == nil, "Follow setting does not invalidate display settings")
            let appearance = restored.appearance(remaining: 50)
            try require(appearance.emoji == "🏂🏻" && appearance.customColor == customColor,
                        "Follow setting preserves the selected custom band appearance")
        }
    }

    private static func invalidDisplaySettings() throws {
        for invalid in [-0.001, 1.001, Double.nan, .infinity, -.infinity] {
            for color in [DisplayColor(red: invalid, green: 0, blue: 0),
                          DisplayColor(red: 0, green: invalid, blue: 0),
                          DisplayColor(red: 0, green: 0, blue: invalid)] {
                var background = QuotaBandSettings.defaults
                background.backgroundColor = color
                try require(background.validationMessage() != nil, "Reject every invalid background channel")
                var band = QuotaBandSettings.defaults
                band.bands[2].customColor = color
                try require(band.validationMessage() != nil, "Reject every invalid band color channel")
            }
            var settings = QuotaBandSettings.defaults
            settings.backgroundOpacity = invalid
            try require(settings.validationMessage() != nil, "Reject nonfinite or out-of-range opacity")
        }
    }

    private static func invalidQuotaResetTime() throws {
        let now = Date(timeIntervalSince1970: 1000)
        for includeDays in [false, true] {
            try require(QuotaResetTime.text(resetAt: nil, now: now, includeDays: includeDays) == nil,
                        "Missing reset time stays unavailable")
            for interval in [Double.nan, .infinity, -.infinity, Double.greatestFiniteMagnitude] {
                try require(QuotaResetTime.text(resetAt: Date(timeIntervalSince1970: interval), now: now,
                                                includeDays: includeDays) == nil,
                            "Invalid or unrepresentable reset interval stays unavailable")
            }
            try require(QuotaResetTime.text(resetAt: now, now: Date(timeIntervalSince1970: .nan),
                                            includeDays: includeDays) == nil,
                        "Invalid current time stays unavailable")
        }
    }

    private static func quotaResetMinutes() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let expected: [(Double, String, String)] = [
            (-61, "0h00m", "0d00h00m"), (-1, "0h00m", "0d00h00m"),
            (0, "0h00m", "0d00h00m"), (0.5, "0h01m", "0d00h01m"),
            (1, "0h01m", "0d00h01m"), (59, "0h01m", "0d00h01m"),
            (60, "0h01m", "0d00h01m"), (60.5, "0h02m", "0d00h02m"),
            (61, "0h02m", "0d00h02m")
        ]
        for (seconds, hoursOnly, withDays) in expected {
            let resetAt = now.addingTimeInterval(seconds)
            try require(QuotaResetTime.text(resetAt: resetAt, now: now, includeDays: false) == hoursOnly,
                        "Minute ceiling at \(seconds) seconds")
            try require(QuotaResetTime.text(resetAt: resetAt, now: now, includeDays: true) == withDays,
                        "Day format uses the same minute ceiling")
        }
    }

    private static func quotaResetHourDays() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let expected: [(Double, String, String)] = [
            (3599, "1h00m", "0d01h00m"), (3600, "1h00m", "0d01h00m"),
            (3 * 3600 + 5 * 60, "3h05m", "0d03h05m"),
            (4 * 3600 + 5 * 60, "4h05m", "0d04h05m"),
            (86399, "24h00m", "1d00h00m"), (86400, "24h00m", "1d00h00m"),
            (86401, "24h01m", "1d00h01m"),
            (6 * 86400 + 22 * 3600 + 10 * 60, "166h10m", "6d22h10m")
        ]
        for (seconds, hoursOnly, withDays) in expected {
            let resetAt = now.addingTimeInterval(seconds)
            try require(QuotaResetTime.text(resetAt: resetAt, now: now, includeDays: false) == hoursOnly,
                        "Hour format and carry at \(seconds) seconds")
            try require(QuotaResetTime.text(resetAt: resetAt, now: now, includeDays: true) == withDays,
                        "Day format and carry at \(seconds) seconds")
        }
    }

    private static func parseUsages(_ fields: String) throws -> QuotaSnapshot {
        try QuotaClient.parse(Data("{\"code\":0,\"data\":{\"kind\":\"ok\",\"quota\":{\"usages\":{\(fields)}}}}".utf8))
    }

    private static func expectQuotaError(_ expected: QuotaClientError, label: String,
                                         action: () throws -> QuotaSnapshot) throws {
        var received: Error?
        do { _ = try action() } catch { received = error }
        try require(received as? QuotaClientError == expected, label)
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(message) }
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
