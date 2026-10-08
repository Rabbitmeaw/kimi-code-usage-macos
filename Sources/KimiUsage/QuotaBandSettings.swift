import Foundation

enum QuotaBandColor: String, Codable, CaseIterable {
    case red, orange, yellow, green, blue, purple
}

struct DisplayColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double

    static let black = DisplayColor(red: 0, green: 0, blue: 0)

    fileprivate var isValid: Bool {
        [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
}

struct QuotaBand: Codable, Equatable {
    var lowerBound: Double
    var emoji: String
    var customColor: DisplayColor? = nil
}

struct QuotaBandSettings: Codable, Equatable {
    var bands: [QuotaBand]
    var backgroundColor: DisplayColor = .black
    var backgroundOpacity: Double = 0.5
    var usesGradient: Bool = false

    private enum CodingKeys: String, CodingKey {
        case bands, backgroundColor, backgroundOpacity, usesGradient
    }

    init(bands: [QuotaBand], backgroundColor: DisplayColor = .black,
         backgroundOpacity: Double = 0.5, usesGradient: Bool = false) {
        self.bands = bands
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        self.usesGradient = usesGradient
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bands = try values.decode([QuotaBand].self, forKey: .bands)
        backgroundColor = try values.decodeIfPresent(DisplayColor.self, forKey: .backgroundColor) ?? .black
        backgroundOpacity = try values.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.5
        usesGradient = try values.decodeIfPresent(Bool.self, forKey: .usesGradient) ?? false
    }

    static let defaults = QuotaBandSettings(bands: [
        QuotaBand(lowerBound: 0, emoji: "😇"),
        QuotaBand(lowerBound: 1, emoji: "🤦‍♀️"),
        QuotaBand(lowerBound: 20, emoji: "🧘"),
        QuotaBand(lowerBound: 40, emoji: "🏂🏻"),
        QuotaBand(lowerBound: 70, emoji: "🪂")
    ])

    static func colors(for count: Int) -> [QuotaBandColor] {
        switch count {
        case 3: return [.red, .yellow, .green]
        case 4: return [.red, .orange, .yellow, .green]
        case 5: return [.red, .orange, .yellow, .green, .blue]
        case 6: return [.red, .orange, .yellow, .green, .blue, .purple]
        default: return []
        }
    }

    func validationMessage() -> String? {
        guard (3...6).contains(bands.count) else { return "请设置 3～6 档额度区间" }
        guard bands.allSatisfy({ $0.lowerBound.isFinite && (0...100).contains($0.lowerBound) }) else {
            return "额度下限必须是 0～100 的有限数值"
        }
        guard bands[0].lowerBound == 0 else { return "最低一档的额度下限必须为 0%" }
        guard zip(bands, bands.dropFirst()).allSatisfy({ $0.0.lowerBound < $0.1.lowerBound }) else {
            return "额度下限必须从低到高严格递增"
        }
        guard bands.allSatisfy({ EmojiInput.isSingleEmoji($0.emoji) }) else {
            return "每一档只能填写一个有效 emoji"
        }
        guard backgroundColor.isValid,
              bands.allSatisfy({ $0.customColor?.isValid ?? true }) else {
            return "颜色通道必须是 0～1 的有限数值"
        }
        guard backgroundOpacity.isFinite, (0...1).contains(backgroundOpacity) else {
            return "背景不透明度必须是 0～1 的有限数值"
        }
        return nil
    }

    func appearance(remaining: Double) -> (emoji: String, color: QuotaBandColor, customColor: DisplayColor?) {
        let palette = Self.colors(for: bands.count)
        guard !palette.isEmpty else { return Self.defaults.appearance(remaining: remaining) }
        let index = bands.lastIndex(where: { remaining >= $0.lowerBound }) ?? 0
        return (bands[index].emoji, palette[index], bands[index].customColor)
    }
}

enum EmojiInput {
    static func isSingleEmoji(_ value: String) -> Bool {
        EmojiCatalog.supported.contains(value)
    }
}
