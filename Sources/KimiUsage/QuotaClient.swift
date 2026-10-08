import CoreFoundation
import Foundation

enum QuotaClientError: Error, LocalizedError, Equatable {
    case desktopUnavailable
    case loginRequired
    case usageUnavailable
    case invalidResponse
    case noUsage

    var errorDescription: String? {
        switch self {
        case .desktopUnavailable: return "未连接 Kimi Code，请先打开官方 App。"
        case .loginRequired: return "Kimi 登录已过期，请回到 App 登录。"
        case .usageUnavailable: return "暂时无法读取 Kimi 额度，请稍后刷新。"
        case .invalidResponse: return "Kimi 额度数据格式已变化。"
        case .noUsage: return "当前账户未返回 5h/7d 额度。"
        }
    }
}

struct QuotaClient {
    let homeDirectory: URL

    init(homeDirectory: URL? = nil) {
        if let homeDirectory {
            self.homeDirectory = homeDirectory
        } else if let customHome = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"], !customHome.isEmpty {
            self.homeDirectory = URL(fileURLWithPath: customHome, isDirectory: true)
        } else {
            self.homeDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code")
        }
    }

    func fetch() async throws -> QuotaSnapshot {
        let token: String
        let instanceFiles: [URL]
        do {
            token = try String(contentsOf: homeDirectory.appendingPathComponent("server.token"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard !token.isEmpty else { throw QuotaClientError.desktopUnavailable }

        let session = URLSession(configuration: .ephemeral, delegate: LocalQuotaSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var lastError = QuotaClientError.desktopUnavailable
        for file in instanceFiles {
            guard let data = try? Data(contentsOf: file),
                  let instance = try? JSONDecoder().decode(ServerInstance.self, from: data),
                  let url = Self.serverURL(host: instance.host, port: instance.port) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 12)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw QuotaClientError.invalidResponse }
                if response.statusCode == 401 || response.statusCode == 403 { throw QuotaClientError.loginRequired }
                guard response.statusCode == 200 else { throw QuotaClientError.usageUnavailable }
                return try Self.parse(data)
            } catch let error as QuotaClientError {
                lastError = error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = .desktopUnavailable
            }
        }
        throw lastError
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
