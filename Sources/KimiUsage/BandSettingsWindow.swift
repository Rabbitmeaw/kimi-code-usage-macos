import AppKit
import Combine
import SwiftUI

private final class BandSettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command {
            let action: Selector?
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": action = #selector(NSText.selectAll(_:))
            case "c": action = #selector(NSText.copy(_:))
            case "v": action = #selector(NSText.paste(_:))
            case "x": action = #selector(NSText.cut(_:))
            default: action = nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class BandSettingsWindowController: NSWindowController {
    init(settings: QuotaBandSettings, onSave: @escaping (QuotaBandSettings) -> Bool) {
        let window = BandSettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 850),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "显示设置"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: window)
        window.contentView = NSHostingView(rootView: BandSettingsView(settings: settings,
            onSave: { [weak self] value in
                if onSave(value) { self?.close() }
            },
            onCancel: { [weak self] in self?.close() }))
    }

    required init?(coder: NSCoder) { return nil }

    func present(near panel: NSPanel) {
        if let window, !window.isVisible {
            let screen = panel.screen ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                              y: visible.midY - window.frame.height / 2))
            } else { window.center() }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct DraftBand: Identifiable {
    let id = UUID()
    var lowerBound: String
    var emoji: String
    var customColor: DisplayColor?

    init(_ band: QuotaBand) {
        lowerBound = band.lowerBound.rounded() == band.lowerBound
            ? String(Int(band.lowerBound)) : String(band.lowerBound)
        emoji = band.emoji
        customColor = band.customColor
    }
}

@MainActor
private final class BandSettingsDraft: ObservableObject {
    @Published var rows: [DraftBand]
    @Published var notice: String?
    @Published var backgroundColor: DisplayColor
    @Published var backgroundOpacity: Double
    @Published var usesGradient: Bool
    @Published var followsKimi: Bool

    init(settings: QuotaBandSettings) {
        rows = settings.bands.map(DraftBand.init)
        backgroundColor = settings.backgroundColor
        backgroundOpacity = settings.backgroundOpacity
        usesGradient = settings.usesGradient
        followsKimi = settings.followsKimi
    }

    func restoreDefaults() {
        let defaults = QuotaBandSettings.defaults
        rows = defaults.bands.map(DraftBand.init)
        backgroundColor = defaults.backgroundColor
        backgroundOpacity = defaults.backgroundOpacity
        usesGradient = defaults.usesGradient
        followsKimi = defaults.followsKimi
        notice = nil
    }
}

@MainActor
private struct BandSettingsView: View {
    @ObservedObject private var draft: BandSettingsDraft
    let onSave: (QuotaBandSettings) -> Void
    let onCancel: () -> Void

    init(settings: QuotaBandSettings, onSave: @escaping (QuotaBandSettings) -> Void,
         onCancel: @escaping () -> Void) {
        draft = BandSettingsDraft(settings: settings)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("显示设置")
                    .font(.system(size: 19, weight: .semibold))
                Text("调整卡片外观。两条额度条共用下方的额度档位。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            runControls
            appearanceControls
            HStack {
                Text("额度条")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Toggle("使用渐变", isOn: $draft.usesGradient)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }
            HStack {
                Text("从低到高 · \(draft.rows.count) 档")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button("增加一档", action: addBand)
                    .disabled(draft.rows.count >= 6)
            }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("颜色").frame(width: 80, alignment: .leading)
                    Text("剩余下限").frame(width: 142, alignment: .leading)
                    Text("展示 emoji").frame(width: 104, alignment: .leading)
                    Spacer()
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
                Divider()
                ForEach(Array(draft.rows.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 12) {
                        HStack(spacing: 6) {
                            ColorPicker("第\(index + 1)档颜色", selection: colorBinding(for: row.id), supportsOpacity: false)
                                .labelsHidden()
                                .frame(width: 16, height: 16)
                                .clipShape(Circle())
                                .overlay {
                                    Circle()
                                        .fill(colorBinding(for: row.id).wrappedValue)
                                        .allowsHitTesting(false)
                                }
                                .padding(4)
                                .contentShape(Circle())
                                .accessibilityLabel("第\(index + 1)档颜色")
                            Text(colorTitle(at: index)).font(.system(size: 12))
                        }
                        .frame(width: 80, alignment: .leading)
                        HStack(spacing: 5) {
                            Text("≥").foregroundStyle(.secondary)
                            TextField("百分比", text: boundBinding(for: row.id))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 74)
                                .disabled(index == 0)
                                .accessibilityLabel("第\(index + 1)档剩余下限")
                            Text("%").foregroundStyle(.secondary)
                        }
                        .frame(width: 142, alignment: .leading)
                        EmojiTextField(value: emojiBinding(for: row.id), label: "第\(index + 1)档表情") {
                            draft.notice = "每档只能输入一个 emoji，请替换原有表情。"
                        }
                        .frame(width: 68, height: 32)
                        .padding(.trailing, 36)
                        Spacer(minLength: 0)
                        Button {
                            draft.rows.removeAll { $0.id == row.id }
                            draft.notice = nil
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(draft.rows.count <= 3 || index == 0)
                        .help(index == 0 ? "最低档从0%开始" : "移除此档")
                        .accessibilityLabel("移除第\(index + 1)档")
                    }
                    .padding(.vertical, 5)
                    if index < draft.rows.count - 1 { Divider() }
                }
            }
            Text("每档从填写的百分比起生效。最少3档，最多6档；最低档固定从0%开始。表情可通过 Control＋Command＋空格输入。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let notice = draft.notice {
                Text(notice)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                Button("恢复默认", action: draft.restoreDefaults)
                Button("退出 Kimi 额度") { NSApp.terminate(nil) }
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 850)
    }

    private var runControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("运行")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Toggle("跟随 Kimi 自动运行", isOn: $draft.followsKimi)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }
            Text("Kimi 启动时打开卡片，退出时关闭。关闭后可手动运行。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private var appearanceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("卡片背景")
                Spacer()
                ColorPicker("背景颜色", selection: backgroundColorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .accessibilityLabel("背景颜色")
            }
            HStack(spacing: 10) {
                Text("背景透明度")
                Slider(value: transparencyBinding, in: 0...100, step: 1)
                    .accessibilityLabel("背景透明度")
                    .accessibilityValue("\(Int(((1 - draft.backgroundOpacity) * 100).rounded()))%")
                Text("\(Int(((1 - draft.backgroundOpacity) * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .font(.system(size: 12))
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private var backgroundColorBinding: Binding<Color> {
        Binding(get: { draft.backgroundColor.swiftUIColor }, set: { value in
            if let color = DisplayColor(value) { draft.backgroundColor = color }
            draft.notice = nil
        })
    }

    private var transparencyBinding: Binding<Double> {
        Binding(get: { (1 - draft.backgroundOpacity) * 100 }, set: { value in
            draft.backgroundOpacity = 1 - value / 100
            draft.notice = nil
        })
    }

    private func colorBinding(for id: UUID) -> Binding<Color> {
        Binding(get: {
            guard let index = draft.rows.firstIndex(where: { $0.id == id }) else { return .clear }
            return draft.rows[index].customColor?.swiftUIColor
                ?? QuotaBandSettings.colors(for: draft.rows.count)[index].swiftUIColor
        }, set: { value in
            guard let index = draft.rows.firstIndex(where: { $0.id == id }),
                  let color = DisplayColor(value) else { return }
            draft.rows[index].customColor = color
            draft.notice = nil
        })
    }

    private func boundBinding(for id: UUID) -> Binding<String> {
        Binding(get: { draft.rows.first { $0.id == id }?.lowerBound ?? "" }, set: { value in
            if let index = draft.rows.firstIndex(where: { $0.id == id }) { draft.rows[index].lowerBound = value }
            draft.notice = nil
        })
    }

    private func emojiBinding(for id: UUID) -> Binding<String> {
        Binding(get: { draft.rows.first { $0.id == id }?.emoji ?? "" }, set: { value in
            if let index = draft.rows.firstIndex(where: { $0.id == id }) { draft.rows[index].emoji = value }
            draft.notice = nil
        })
    }

    private func parsedSettings() -> QuotaBandSettings? {
        var bands: [QuotaBand] = []
        for (index, row) in draft.rows.enumerated() {
            guard let boundary = Double(row.lowerBound) else {
                draft.notice = "第\(index + 1)档的下限需要填写0～100的数字。"
                return nil
            }
            bands.append(QuotaBand(lowerBound: boundary, emoji: row.emoji, customColor: row.customColor))
        }
        let settings = QuotaBandSettings(bands: bands, backgroundColor: draft.backgroundColor,
                                        backgroundOpacity: draft.backgroundOpacity, usesGradient: draft.usesGradient,
                                        followsKimi: draft.followsKimi)
        if let error = settings.validationMessage() { draft.notice = error; return nil }
        return settings
    }

    private func addBand() {
        guard draft.rows.count < 6, let settings = parsedSettings() else { return }
        let bands = settings.bands
        let index = bands.indices.max { left, right in
            gap(after: left, bands: bands) < gap(after: right, bands: bands)
        } ?? 0
        let boundary = bands[index].lowerBound + gap(after: index, bands: bands) / 2
        draft.rows.insert(DraftBand(QuotaBand(lowerBound: boundary, emoji: "✨")), at: index + 1)
        draft.notice = nil
    }

    private func gap(after index: Int, bands: [QuotaBand]) -> Double {
        (index + 1 < bands.count ? bands[index + 1].lowerBound : 100) - bands[index].lowerBound
    }

    private func save() {
        guard let settings = parsedSettings() else { return }
        onSave(settings)
    }

    private func colorTitle(at index: Int) -> String {
        draft.rows[index].customColor == nil
            ? QuotaBandSettings.colors(for: draft.rows.count)[index].title : "自定"
    }
}

private struct EmojiTextField: NSViewRepresentable {
    @Binding var value: String
    let label: String
    let onRejected: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: value)
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: 22)
        field.alignment = .center
        field.bezelStyle = .roundedBezel
        field.setAccessibilityLabel(label)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != value { field.stringValue = value }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: EmojiTextField

        init(_ parent: EmojiTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let candidate = field.stringValue
            if candidate.isEmpty || EmojiInput.isSingleEmoji(candidate) {
                parent.value = candidate
            } else {
                field.stringValue = parent.value
                if let editor = field.currentEditor() {
                    editor.string = parent.value
                    editor.selectedRange = NSRange(location: parent.value.utf16.count, length: 0)
                }
                parent.onRejected()
            }
        }
    }
}
