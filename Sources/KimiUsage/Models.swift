import Foundation

struct QuotaWindow: Equatable {
    let usedFraction: Double
    let resetAt: Date?

    var usedPercent: Double { min(1, max(0, usedFraction)) * 100 }
}

struct QuotaSnapshot: Equatable {
    let fiveHour: QuotaWindow?
    let sevenDay: QuotaWindow?
    let updatedAt: Date
}

enum QuotaResetTime {
    static func text(resetAt: Date?, now: Date, includeDays: Bool) -> String? {
        guard let resetAt else { return nil }
        let interval = resetAt.timeIntervalSince(now)
        guard interval.isFinite,
              let totalMinutes = Int(exactly: ceil(max(0, interval) / 60)) else { return nil }
        let minutes = twoDigits(totalMinutes % 60)
        let hours = totalMinutes / 60
        if includeDays {
            return "\(hours / 24)d\(twoDigits(hours % 24))h\(minutes)m"
        }
        return "\(hours)h\(minutes)m"
    }

    private static func twoDigits(_ number: Int) -> String {
        (number < 10 ? "0" : "") + String(number)
    }
}
