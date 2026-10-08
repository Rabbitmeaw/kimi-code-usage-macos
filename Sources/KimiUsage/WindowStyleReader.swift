import Foundation
import CoreGraphics

enum WindowStyleReader {
    struct Measurement {
        let insets: WindowChromeInsets?
        let status: String
    }

    static func read(bundleURL: URL, displayScale: CGFloat = 2) -> Measurement {
        let directory = bundleURL.appendingPathComponent("Contents/Resources/desktop-dist", isDirectory: true)
        do {
            let html = try String(contentsOf: directory.appendingPathComponent("index.html"), encoding: .utf8)
            let links = matches(#"<link\b[^>]*>"#, in: html)
            var styles: [String] = []
            for link in links {
                guard attribute("rel", in: link) == "stylesheet",
                      let href = attribute("href", in: link),
                      href.hasPrefix("/assets/"), href.hasSuffix(".css") else { continue }
                let file = directory.appendingPathComponent(String(href.dropFirst())).standardizedFileURL
                guard file.path.hasPrefix(directory.standardizedFileURL.path + "/") else { continue }
                styles.append(try String(contentsOf: file, encoding: .utf8))
            }
            guard !styles.isEmpty,
                  let insets = parse(css: styles.joined(separator: "\n"), displayScale: displayScale) else {
                return Measurement(insets: nil, status: "尚未识别 Kimi 窗口样式栏高")
            }
            return Measurement(insets: insets, status: "已读取 Kimi 样式栏高")
        } catch {
            return Measurement(insets: nil, status: "暂时无法读取 Kimi 安装样式")
        }
    }

    // The installed desktop layout at its default page zoom. Font steps remain below
    // the account avatar height; only the resolution media query changes the hairline.
    static func parse(css: String, displayScale: CGFloat = 2) -> WindowChromeInsets? {
        guard displayScale.isFinite, displayScale > 0 else { return nil }
        let clean = replacing(#"/\*[\s\S]*?\*/"#, in: css, with: "")
        var variables: [String: String] = [:]
        var styles: [String: [String: String]] = [:]
        collectRules(clean, displayScale: Double(displayScale), variables: &variables, styles: &styles)
        func scalar(_ value: String?) -> Double? {
            guard let value else { return nil }
            return ScalarParser.evaluate(value, variables: variables)
        }
        func property(_ name: String, _ key: String) -> Double? { scalar(styles[name]?[key]) }
        func padding(_ name: String) -> (Double, Double)? {
            guard let text = styles[name]?["padding"] else { return nil }
            let pieces = components(text)
            guard (1...4).contains(pieces.count), let top = scalar(pieces[0]),
                  let bottom = scalar(pieces.count > 2 ? pieces[2] : pieces[0]) else { return nil }
            return (top, bottom)
        }

        guard styles["chat-header"]?["height"] != nil,
              styles["side-footer"]?["display"] == "flex",
              styles["user-menu-trigger"]?["display"] == "flex",
              let top = property("chat-header", "height"),
              let footerPadding = padding("side-footer"),
              let triggerPadding = padding("user-menu-trigger"),
              let avatar = property("user-menu-avatar", "height"),
              let badge = property("ui-badge--sm", "height"),
              let settings = property("ui-icon-button--sm", "height"),
              let fontSize = property("user-menu-trigger", "font-size"),
              let lineHeight = property("user-menu-trigger", "line-height"),
              let borderText = styles["side-footer"]?["border-top"],
              let borderWidth = components(borderText).first.flatMap({ scalar($0) }) else { return nil }
        let account = triggerPadding.0 + max(avatar, max(badge, fontSize * lineHeight)) + triggerPadding.1
        let bottom = footerPadding.0 + max(account, settings) + footerPadding.1 + borderWidth
        guard [top, bottom, avatar, badge, settings, fontSize, lineHeight].allSatisfy({ $0.isFinite && $0 > 0 }),
              [footerPadding.0, footerPadding.1, triggerPadding.0, triggerPadding.1, borderWidth]
                .allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        return WindowChromeInsets(top: CGFloat(top), bottom: CGFloat(bottom))
    }

    private static func collectRules(_ text: String, displayScale: Double,
                                     variables: inout [String: String],
                                     styles: inout [String: [String: String]]) {
        var cursor = text.startIndex
        while cursor < text.endIndex, let open = text[cursor...].firstIndex(of: "{"),
              let close = closingBrace(in: text, after: open) {
            let selector = String(text[cursor..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
            let body = String(text[text.index(after: open)..<close])
            if selector.hasPrefix("@media") {
                if let limit = capture(#"max-resolution\s*:\s*([0-9.]+)dppx"#, in: selector).flatMap(Double.init),
                   displayScale <= limit {
                    collectRules(body, displayScale: displayScale, variables: &variables, styles: &styles)
                }
            } else if !selector.hasPrefix("@") {
                var declarations: [String: String] = [:]
                for declaration in body.split(separator: ";") {
                    guard let colon = declaration.firstIndex(of: ":") else { continue }
                    let name = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
                    declarations[name] = declaration[declaration.index(after: colon)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                for raw in selector.split(separator: ",") {
                    let item = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if item == ":root" || item == "html[data-font-scale=medium]" {
                        variables.merge(declarations.filter { $0.key.hasPrefix("--") }) { _, new in new }
                    } else {
                        let plain = replacing(#"\[data-v-[^\]]+\]"#, in: item, with: "")
                        if plain.hasPrefix("."), plain.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
                            let name = String(plain.dropFirst())
                            styles[name, default: [:]].merge(declarations) { _, new in new }
                        }
                    }
                }
            }
            cursor = text.index(after: close)
        }
    }

    private static func closingBrace(in text: String, after open: String.Index) -> String.Index? {
        var depth = 1
        var quote: Character?
        var escaped = false
        var index = text.index(after: open)
        while index < text.endIndex {
            let character = text[index]
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if let current = quote {
                if character == current { quote = nil }
            } else if character == "\"" || character == "'" { quote = character }
            else if character == "{" { depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func components(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if character.isWhitespace && depth == 0 {
                if !current.isEmpty { result.append(current); current = "" }
            } else { current.append(character) }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func attribute(_ name: String, in text: String) -> String? {
        capture("\\b" + name + #"\s*=\s*[\"']([^\"']+)[\"']"#, in: text)
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: replacement)
    }

    // Only the px/unitless, var(), calc() and arithmetic used by these layout tokens.
    private struct ScalarParser {
        let characters: [Character]
        var index = 0

        static func evaluate(_ text: String, variables: [String: String], depth: Int = 0) -> Double? {
            guard depth < 16 else { return nil }
            var expanded = text
            let pattern = #"var\(\s*(--[\w-]+)\s*(?:,\s*([^()]+))?\)"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            while let match = regex.firstMatch(in: expanded, range: NSRange(expanded.startIndex..., in: expanded)) {
                guard let full = Range(match.range, in: expanded),
                      let name = Range(match.range(at: 1), in: expanded) else { return nil }
                let fallback = Range(match.range(at: 2), in: expanded).map { String(expanded[$0]) }
                guard let value = variables[String(expanded[name])] ?? fallback,
                      let number = evaluate(value, variables: variables, depth: depth + 1) else { return nil }
                expanded.replaceSubrange(full, with: String(number))
            }
            expanded = expanded.replacingOccurrences(of: "calc", with: "").replacingOccurrences(of: "px", with: "")
            var parser = ScalarParser(characters: Array(expanded.filter { !$0.isWhitespace }))
            guard let value = parser.sum(), parser.index == parser.characters.count, value.isFinite else { return nil }
            return value
        }

        mutating func sum() -> Double? {
            guard var value = product() else { return nil }
            while index < characters.count, characters[index] == "+" || characters[index] == "-" {
                let operation = characters[index]; index += 1
                guard let next = product() else { return nil }
                value = operation == "+" ? value + next : value - next
            }
            return value
        }

        mutating func product() -> Double? {
            guard var value = atom() else { return nil }
            while index < characters.count, characters[index] == "*" || characters[index] == "/" {
                let operation = characters[index]; index += 1
                guard let next = atom(), operation != "/" || next != 0 else { return nil }
                value = operation == "*" ? value * next : value / next
            }
            return value
        }

        mutating func atom() -> Double? {
            guard index < characters.count else { return nil }
            if characters[index] == "(" {
                index += 1
                guard let value = sum(), index < characters.count, characters[index] == ")" else { return nil }
                index += 1
                return value
            }
            let start = index
            if characters[index] == "-" || characters[index] == "+" { index += 1 }
            while index < characters.count, characters[index].isNumber || characters[index] == "." { index += 1 }
            return Double(String(characters[start..<index]))
        }
    }
}
