import Foundation
import Darwin

struct FollowKimiService {
    static let label = "com.yokinri.kimi-usage.follow"

    private static var serviceTarget: String { "gui/\(getuid())/\(label)" }
    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func setEnabled(_ enabled: Bool, appURL: URL = Bundle.main.bundleURL) throws {
        let manager = FileManager.default
        let registered = try launchctl(["print", serviceTarget]) == 0
        if !enabled {
            if registered, try launchctl(["bootout", serviceTarget]) != 0 {
                throw ServiceError.registrationFailed
            }
            if manager.fileExists(atPath: plistURL.path) { try manager.removeItem(at: plistURL) }
            return
        }

        let helper = appURL.appendingPathComponent(
            "Contents/Library/LoginItems/Kimi Usage Watcher.app/Contents/MacOS/KimiUsageWatcher")
        guard manager.isExecutableFile(atPath: helper.path) else { throw ServiceError.helperUnavailable }
        let definition: [String: Any] = [
            "Label": label,
            "ProgramArguments": [helper.path, "--app-path", appURL.path],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Background",
            "LimitLoadToSessionType": "Aqua"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0)
        if registered, (try? Data(contentsOf: plistURL)) == data { return }
        if registered, try launchctl(["bootout", serviceTarget]) != 0 {
            throw ServiceError.registrationFailed
        }
        try manager.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plistURL.path)
        guard try launchctl(["bootstrap", "gui/\(getuid())", plistURL.path]) == 0 else {
            throw ServiceError.registrationFailed
        }
    }

    private static func launchctl(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private enum ServiceError: Error {
        case helperUnavailable
        case registrationFailed
    }
}
