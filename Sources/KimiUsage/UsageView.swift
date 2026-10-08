import AppKit
import SwiftUI

struct UsageView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            VStack(alignment: .leading, spacing: isFree ? 4 : 7.8) {
                if isFree {
                    header
                }
                quotaRow("5 小时", quota: store.snapshot?.fiveHour, now: context.date, includeDays: false)
                quotaRow("7 天", quota: store.snapshot?.sevenDay, now: context.date, includeDays: true)
                footer
            }
        }
        .padding(10.4)
        .frame(width: 203, height: 117)
        .foregroundStyle(.white)
        .background(store.bandSettings.backgroundColor.swiftUIColor.opacity(store.bandSettings.backgroundOpacity),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.65)
        }
    }

    private var isFree: Bool { store.corner == .free }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Kimi 额度")
                .font(.system(size: 10.4, weight: .semibold))
            Spacer(minLength: 6.5)
            Text("拖动")
                .font(.system(size: 8.5))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
        }
    }

    private var footer: some View {
        HStack(spacing: 5.2) {
            if let snapshot = store.snapshot {
                Text("更新 \(updatedTime(snapshot.updatedAt))")
                    .foregroundStyle(.white.opacity(0.72))
            } else if store.errorMessage != nil {
                Text("获取失败")
                    .foregroundStyle(.white.opacity(0.90))
            } else {
                Text(store.isRefreshing ? "获取中…" : "等待首次更新")
                    .foregroundStyle(.white.opacity(0.72))
            }
            Spacer(minLength: 3.9)
            Text(footerStatus)
                .foregroundStyle(.white.opacity(store.errorMessage == nil ? 0.50 : 0.90))
        }
        .font(.system(size: 8.5))
        .monospacedDigit()
        .lineLimit(1)
    }

    private func updatedTime(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }

    private var footerStatus: String {
        if store.errorMessage != nil { return store.snapshot == nil ? "等待重试" : "更新失败" }
        if store.isRefreshing { return "更新中…" }
        return "右键管理"
    }

    private func quotaRow(_ title: String, quota: QuotaWindow?, now: Date, includeDays: Bool) -> some View {
        let remaining = quota.map { 100 - $0.usedPercent }
        let appearance: (emoji: String, color: Color) = {
            guard let remaining else {
                return (store.snapshot == nil ? "⏳" : "➖", .white.opacity(0.60))
            }
            let band = store.bandSettings.appearance(remaining: remaining)
            return (band.emoji, band.customColor?.swiftUIColor ?? band.color.swiftUIColor)
        }()

        return HStack(spacing: 6.5) {
            Text(appearance.emoji)
                .font(.system(size: 18.2))
                .frame(width: 20.8)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: isFree ? 2 : 3.9) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: 9.1, weight: .medium))
                    Spacer(minLength: 6.5)
                    if let remaining {
                        Text("剩余 \(remaining.formatted(.number.precision(.fractionLength(0...1))))%")
                            .font(.system(size: 9.1, weight: .semibold))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                    } else {
                        Text(store.snapshot == nil ? "— · 尚未获取" : "— · 未提供")
                            .font(.system(size: 8.5))
                            .foregroundStyle(.white.opacity(0.60))
                    }
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.16))
                        Capsule()
                            .fill(barFill(appearance.color))
                            .frame(width: geometry.size.width * (remaining ?? 0) / 100)
                    }
                }
                .frame(height: 4.6)
                .opacity(remaining == nil ? 0.4 : 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(title)剩余额度")
                .accessibilityValue(remaining.map { "\($0.formatted(.number.precision(.fractionLength(0...1))))%" } ?? (store.snapshot == nil ? "尚未获取" : "未提供"))

                Text(resetDescription(quota: quota, now: now, includeDays: includeDays))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.white.opacity(0.65))
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }

    private func resetDescription(quota: QuotaWindow?, now: Date, includeDays: Bool) -> String {
        guard store.snapshot != nil else { return "重置 · 尚未获取" }
        guard let text = QuotaResetTime.text(resetAt: quota?.resetAt, now: now, includeDays: includeDays) else {
            return "重置 · 未提供"
        }
        return "重置 \(text)"
    }

    private func barFill(_ color: Color) -> AnyShapeStyle {
        if store.bandSettings.usesGradient {
            let base = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
            let light = base.blended(withFraction: 0.55, of: .white) ?? base
            return AnyShapeStyle(LinearGradient(colors: [Color(nsColor: light.withAlphaComponent(1)), color],
                                                startPoint: .leading, endPoint: .trailing))
        }
        return AnyShapeStyle(color)
    }
}
