import CoreFoundation
import Darwin
import Foundation
import Security

enum QuotaClientError: Error, LocalizedError, Equatable {
    case desktopUnavailable
    case localTokenUnavailable
    case localAuthorizationFailed
    case loginRequired
    case usageUnavailable
    case invalidResponse
    case noUsage

    var errorDescription: String? {
        switch self {
        case .desktopUnavailable: return "未连接 Kimi Code，请先打开官方 App。"
        case .localTokenUnavailable: return "Kimi 本地令牌不可用，请检查 server.token 的内容与权限。"
        case .localAuthorizationFailed: return "Kimi 本地服务拒绝访问，请检查令牌与数据目录。"
        case .loginRequired: return "Kimi 登录已过期，请回到 App 登录。"
        case .usageUnavailable: return "暂时无法读取 Kimi 额度，请稍后刷新。"
        case .invalidResponse: return "Kimi 额度数据格式已变化。"
        case .noUsage: return "当前账户未返回 5h/7d 额度。"
        }
    }
}

struct QuotaClient {
    let homeDirectory: URL
    private let sessionConfiguration: URLSessionConfiguration

    init(homeDirectory: URL? = nil, sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.sessionConfiguration = sessionConfiguration
        if let homeDirectory {
            self.homeDirectory = homeDirectory
        } else if let customHome = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"], !customHome.isEmpty {
            self.homeDirectory = URL(fileURLWithPath: customHome, isDirectory: true)
        } else {
            self.homeDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code")
        }
    }

    func fetch(retryDelays: [UInt64] = [1_000_000_000, 2_000_000_000, 4_000_000_000, 8_000_000_000]) async throws -> QuotaSnapshot {
        var delays = retryDelays.makeIterator()
        while true {
            try Task.checkCancellation()
            do {
                return try await fetchOnce()
            } catch let error as QuotaClientError where error == .desktopUnavailable || error == .localTokenUnavailable {
                guard let delay = delays.next() else { throw error }
                try await Task.sleep(nanoseconds: delay)
            }
        }
    }

    private func fetchOnce() async throws -> QuotaSnapshot {
        let instanceFiles: [URL]
        do {
            instanceFiles = try FileManager.default.contentsOfDirectory(
                at: homeDirectory.appendingPathComponent("server/instances"),
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }.sorted {
                let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return first > second
            }
        } catch {
            throw QuotaClientError.desktopUnavailable
        }
        let urls = instanceFiles.compactMap { file -> URL? in
            guard let data = try? Data(contentsOf: file),
                  let instance = try? JSONDecoder().decode(ServerInstance.self, from: data) else { return nil }
            return Self.serverURL(host: instance.host, port: instance.port)
        }
        guard !urls.isEmpty else { throw QuotaClientError.desktopUnavailable }
        try Task.checkCancellation()
        let token = try localToken()

        let session = URLSession(configuration: sessionConfiguration, delegate: LocalQuotaSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var responseError: QuotaClientError?
        for url in urls {
            try Task.checkCancellation()
            var request = URLRequest(url: url, timeoutInterval: 12)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw QuotaClientError.invalidResponse }
                if response.statusCode == 401 || response.statusCode == 403 { throw QuotaClientError.localAuthorizationFailed }
                guard response.statusCode == 200 else { throw QuotaClientError.usageUnavailable }
                return try Self.parse(data)
            } catch let error as QuotaClientError {
                if responseError == nil { responseError = error }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
            }
        }
        throw responseError ?? QuotaClientError.desktopUnavailable
    }

    private func localToken() throws -> String {
        let path = homeDirectory.appendingPathComponent("server.token").path
        let existing = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if existing >= 0 { return try Self.readToken(descriptor: existing) }
        guard errno == ENOENT else { throw QuotaClientError.localTokenUnavailable }

        // Desktop accepts this private persistent token in addition to its renderer's in-memory secret.
        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw QuotaClientError.localTokenUnavailable }
        let token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let temporaryPath = homeDirectory.appendingPathComponent(".server-token-\(UUID().uuidString).tmp").path
        let descriptor = open(temporaryPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw QuotaClientError.localTokenUnavailable }
        defer {
            close(descriptor)
            unlink(temporaryPath)
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw QuotaClientError.localTokenUnavailable }
        let data = Data((token + "\n").utf8)
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw QuotaClientError.localTokenUnavailable }
                offset += written
            }
        }
        // Publish the complete file atomically; link cannot overwrite a concurrent creator's token.
        if link(temporaryPath, path) == 0 { return token }
        guard errno == EEXIST else { throw QuotaClientError.localTokenUnavailable }
        let winner = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard winner >= 0 else { throw QuotaClientError.localTokenUnavailable }
        return try Self.readToken(descriptor: winner)
    }

    private static func readToken(descriptor: Int32) throws -> String {
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_mode & 0o077 == 0,
              metadata.st_uid == geteuid() else { throw QuotaClientError.localTokenUnavailable }
        let data: Data
        do {
            data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
        } catch {
            throw QuotaClientError.localTokenUnavailable
        }
        guard let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { throw QuotaClientError.localTokenUnavailable }
        return token
    }

    static func serverURL(host: String, port: Int) -> URL? {
        guard ["localhost", "127.0.0.1", "::1"].contains(host.lowercased()), (1...65535).contains(port) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host == "::1" ? "[::1]" : host
        components.port = port
        components.path = "/api/v1/oauth/usage"
        components.queryItems = [URLQueryItem(name: "provider", value: "managed:kimi-code")]
        return components.url
    }

    static func parse(_ data: Data, updatedAt: Date = Date()) throws -> QuotaSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = root["code"] as? Int else { throw QuotaClientError.invalidResponse }
        guard code == 0 else {
            throw (40100..<40200).contains(code) ? QuotaClientError.loginRequired : QuotaClientError.usageUnavailable
        }
        guard let result = root["data"] as? [String: Any], let kind = result["kind"] as? String else {
            throw QuotaClientError.invalidResponse
        }
        if kind == "error" {
            let status = result["status"] as? Int
            let message = (result["message"] as? String ?? "").lowercased()
            if status == 401 || status == 403 || ["login", "log in", "sign in", "authorization"].contains(where: message.contains) {
                throw QuotaClientError.loginRequired
            }
            throw QuotaClientError.usageUnavailable
        }
        guard kind == "ok", let quota = result["quota"] as? [String: Any],
              let usages = quota["usages"] as? [String: Any] else { throw QuotaClientError.invalidResponse }
        let fiveHour = try parseWindow(usages["limit5h"])
        let sevenDay = try parseWindow(usages["limit7d"])
        guard fiveHour != nil || sevenDay != nil else { throw QuotaClientError.noUsage }
        return QuotaSnapshot(fiveHour: fiveHour, sevenDay: sevenDay, updatedAt: updatedAt)
    }

    private static func parseWindow(_ value: Any?) throws -> QuotaWindow? {
        guard let value, !(value is NSNull) else { return nil }
        guard let entry = value as? [String: Any] else { throw QuotaClientError.invalidResponse }
        let ratio: Double?
        if let number = entry["usedRatio"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            ratio = number.doubleValue
        } else if let string = entry["usedRatio"] as? String {
            ratio = Double(string)
        } else {
            ratio = nil
        }
        guard let ratio, ratio.isFinite, (0...1).contains(ratio) else { throw QuotaClientError.invalidResponse }
        let resetAt: Date?
        if let timestamp = entry["resetAt"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            resetAt = formatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
        } else {
            resetAt = nil
        }
        return QuotaWindow(usedFraction: ratio, resetAt: resetAt)
    }
}

private struct ServerInstance: Decodable {
    let host: String
    let port: Int
}

private final class LocalQuotaSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
