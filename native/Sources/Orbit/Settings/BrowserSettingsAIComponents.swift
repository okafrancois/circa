import AppKit
import BrowserCore
import BrowserShell
import SwiftUI

/// Settings › AI timing and colours (board values).
@MainActor
enum BrowserSettingsAIStyle {
    /// Everything below the master switch is dimmed while AI is off.
    static let dimmedOpacity = 0.42
    static let dimmedSaturation = 0.4
    static var dim: Animation {
        OrbitMotionPreferences.prefersReducedMotion ? .linear(duration: 0.15) : .easeOut(duration: 0.3)
    }
    /// Usage bars fill from zero when shown: 'bow' 0.6 s after 0.1 s.
    static var meterFill: Animation? {
        OrbitMotionPreferences.prefersReducedMotion ? nil : .timingCurve(0.19, 1, 0.22, 1, duration: 0.6).delay(0.1)
    }
    static var disclosure: Animation? {
        OrbitMotionPreferences.prefersReducedMotion ? nil : .timingCurve(0.19, 1, 0.22, 1, duration: 0.3)
    }
    static let ready = Color(nsColor: BrandPalette.rgb(0x28C840))
    static let warning = Color(nsColor: BrandPalette.rgb(0xFF9F0A))
    static let full = Color(nsColor: BrandPalette.rgb(0xFF3B30))
    static let tertiary = dynamic(light: 0x96929E, dark: 0x7D7884)
    static let track = dynamic(light: 0xE5E0D8, dark: 0x37353D)
    static let meterInk = dynamic(light: 0x5E5A66, dark: 0xB4AFBA)
    static let fill = dynamic(light: 0xEFEBE4, dark: 0x2C2B32)
    static let tileBorder = Color.primary.opacity(0.09)

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            BrandPalette.rgb(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }
}

/// A program's mark from `Icons/ai-marks/<provider>.svg` (listed under `aiMarks` in the icon
/// catalog). The shipped files are neutral placeholders: a letter monogram on a neutral disc, in
/// the slot and size of the programs' own marks, which need their owners' written permission
/// before a public release. Replacing a file is the whole swap: marks drawn in `currentColor`
/// follow the appearance's ink, other colours are kept.
enum BrowserSettingsAIMark {
    @MainActor private static var cache: [BrowserAIProviderID: NSImage] = [:]

    @MainActor static func image(_ provider: BrowserAIProviderID) -> NSImage? {
        if let cached = cache[provider] { return cached }
        guard let url = BrowserText.iconResource("ai-marks/" + provider.rawValue, extension: "svg"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        func variant(_ ink: String) -> NSImage? { NSImage(data: Data(source.replacingOccurrences(of: "currentColor", with: ink).utf8)) }
        let light = variant("#000000"), dark = variant("#FFFFFF")
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            (isDark ? dark : light)?.draw(in: rect)
            return true
        }
        image.cacheMode = .never
        cache[provider] = image
        return image
    }
}

/// The 32 pt tile in front of a program row.
struct BrowserSettingsAIProgramTile: View {
    let provider: BrowserAIProviderID
    var body: some View {
        ZStack {
            if provider == .onDevice {
                RoundedRectangle(cornerRadius: 8).fill(BrowserSettingsAIStyle.fill)
                OrbitIcon.view(sfName: "laptopcomputer", pointSize: 18).font(.system(size: 18)).frame(width: 18, height: 18)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(OrbitSettingsStyle.panel)
                RoundedRectangle(cornerRadius: 8).strokeBorder(BrowserSettingsAIStyle.tileBorder, lineWidth: 1)
                if let mark = BrowserSettingsAIMark.image(provider) {
                    Image(nsImage: mark).resizable().frame(width: 19, height: 19)
                }
            }
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }
}

/// "5 hours ▬▬▬ 42% · resets 14:20": neutral below 80 %, orange from 80 %, red at the limit.
struct BrowserSettingsAIMeters: View {
    let usage: BrowserAIUsage
    @State private var shown = false

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
            ForEach(Array(usage.windows.enumerated()), id: \.offset) { _, window in
                GridRow {
                    Text(BrowserSettingsAIText.span(window.span)).frame(width: 52, alignment: .leading).lineLimit(1)
                    ZStack(alignment: .leading) {
                        Capsule().fill(BrowserSettingsAIStyle.track)
                        Capsule().fill(color(window)).frame(width: shown ? 120 * CGFloat(window.usedPercent) / 100 : 0)
                    }
                    .frame(width: 120, height: 4)
                    .accessibilityHidden(true)
                    Text(BrowserSettingsAIText.meter(window, limitReached: usage.limitReached && window.isFull))
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .font(Font(BrandFonts.ui(11.5)))
        .foregroundStyle(BrowserSettingsAIStyle.tertiary)
        .padding(.top, 6)
        .onAppear {
            if let animation = BrowserSettingsAIStyle.meterFill { withAnimation(animation) { shown = true } } else { shown = true }
        }
    }

    private func color(_ window: BrowserAIUsageWindow) -> Color {
        window.isFull ? BrowserSettingsAIStyle.full : window.usedPercent >= 80 ? BrowserSettingsAIStyle.warning : BrowserSettingsAIStyle.meterInk
    }
}

/// Status line: coloured dot and text.
struct BrowserSettingsAIStateLine: View {
    enum Tone { case ready, warning, neutral }
    let tone: Tone
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tone == .ready ? BrowserSettingsAIStyle.ready : tone == .warning ? BrowserSettingsAIStyle.warning : BrowserSettingsAIStyle.tertiary)
                .frame(width: 7, height: 7)
            Text(text)
        }
        .font(Font(BrandFonts.ui(12)))
        .foregroundStyle(BrowserSettingsAIStyle.tertiary)
    }
}

/// One entry of a model menu. Disabled entries show their reason at the trailing edge.
struct BrowserSettingsAIMenuEntry: Equatable {
    var choice: BrowserAIModelChoice?
    var title: String
    var reason: String?
    var startsGroup = false
}

/// Native pop-up button whose disabled items carry a right-aligned reason, as the board shows.
struct BrowserSettingsAIModelPopUp: NSViewRepresentable {
    let entries: [BrowserSettingsAIMenuEntry]
    let selected: BrowserAIModelChoice?
    let title: String
    let select: (BrowserAIModelChoice) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.autoenablesItems = false
        button.controlSize = .small
        button.font = BrandFonts.ui(12)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.select = select
        button.setAccessibilityLabel(title)
        guard context.coordinator.entries != entries || context.coordinator.selected != selected else { return }
        context.coordinator.entries = entries
        context.coordinator.selected = selected
        let menu = NSMenu()
        menu.autoenablesItems = false
        let font = BrandFonts.ui(13)
        let widest = entries.map { ($0.title as NSString).size(withAttributes: [.font: font]).width
            + ($0.reason.map { ($0 as NSString).size(withAttributes: [.font: BrandFonts.ui(11)]).width + 28 } ?? 0) }.max() ?? 0
        for (index, entry) in entries.enumerated() {
            if entry.startsGroup && index > 0 { menu.addItem(.separator()) }
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            item.tag = index
            item.isEnabled = entry.reason == nil
            if let reason = entry.reason {
                let style = NSMutableParagraphStyle()
                style.tabStops = [NSTextTab(textAlignment: .right, location: ceil(widest))]
                let title = NSMutableAttributedString(string: entry.title + "\t", attributes: [.font: font, .paragraphStyle: style,
                    .foregroundColor: NSColor.disabledControlTextColor])
                title.append(NSAttributedString(string: reason, attributes: [.font: BrandFonts.ui(11), .paragraphStyle: style,
                    .foregroundColor: NSColor.tertiaryLabelColor]))
                item.attributedTitle = title
                item.setAccessibilityLabel(entry.title + ", " + reason)
            }
            menu.addItem(item)
        }
        button.menu = menu
        if let index = entries.firstIndex(where: { $0.choice == selected }) { button.selectItem(at: menu.indexOfItem(withTag: index)) }
        button.sizeToFit()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        nsView.fittingSize
    }

    @MainActor final class Coordinator: NSObject {
        var entries: [BrowserSettingsAIMenuEntry] = []
        var selected: BrowserAIModelChoice?
        var select: ((BrowserAIModelChoice) -> Void)?
        @objc func changed(_ sender: NSPopUpButton) {
            guard let tag = sender.selectedItem?.tag, entries.indices.contains(tag), let choice = entries[tag].choice else { return }
            selected = choice
            select?(choice)
        }
    }
}

/// Display text for programs, plans, usage windows and reset times.
enum BrowserSettingsAIText {
    static var applicationName: String { ProductIdentity.displayName }

    static func name(_ provider: BrowserAIProviderID) -> String {
        switch provider {
        case .codex: uiText("Codex")
        case .claudeCode: uiText("Claude Code")
        case .onDevice: uiText("On This Mac")
        }
    }

    /// Plan names are the providers' product names; only the plan type is ever read.
    static func plan(_ provider: BrowserAIProviderID, _ raw: String?) -> String? {
        guard let raw else { return nil }
        if raw == "apiKey" { return uiText("API key") }
        let codex = ["free": "Free", "go": "Go", "plus": "Plus", "pro": "Pro", "prolite": "Pro Lite", "promax": "Pro Max",
                     "team": "Team", "business": "Business", "enterprise": "Enterprise", "edu": "Edu"]
        let claude = ["free": "Free", "pro": "Pro", "max": "Max", "team": "Team", "enterprise": "Enterprise"]
        switch provider {
        case .codex: return codex[raw].map { "ChatGPT " + $0 } ?? "ChatGPT"
        case .claudeCode: return claude[raw].map { "Claude " + $0 } ?? "Claude"
        case .onDevice: return nil
        }
    }

    static func span(_ span: BrowserAIUsageWindow.Span) -> String {
        switch span {
        case .fiveHours: return uiText("5 hours")
        case .week: return uiText("Week")
        case .minutes(let minutes):
            if minutes == 1440 { return uiText("Day") }
            if (40_320...44_640).contains(minutes) { return uiText("Month") }
            if minutes >= 120, minutes % 60 == 0 { return uiFormat("%ld hours", minutes / 60) }
            return uiFormat("%ld min", minutes)
        }
    }

    static func meter(_ window: BrowserAIUsageWindow, limitReached: Bool, now: Date = Date()) -> String {
        guard let reset = window.resetsAt else {
            return limitReached ? uiText("Limit reached") : uiFormat("%ld%%", window.usedPercent)
        }
        let when = resetTime(reset, now: now)
        return limitReached ? uiFormat("Limit reached · resets %@", when) : uiFormat("%ld%% · resets %@", window.usedPercent, when)
    }

    /// Today: a time; this week: a weekday; later: a date.
    static func resetTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        if calendar.isDate(date, inSameDayAs: now) { formatter.setLocalizedDateFormatFromTemplate("jmm") }
        else if date > now, date.timeIntervalSince(now) < 6 * 86_400 { formatter.setLocalizedDateFormatFromTemplate("EEEE") }
        else { formatter.setLocalizedDateFormatFromTemplate("dMMM") }
        return formatter.string(from: date)
    }

    static func effort(_ raw: String) -> String {
        switch raw {
        case "low": uiText("Low")
        case "medium": uiText("Medium")
        case "high": uiText("High")
        case "xhigh": uiText("Extra High")
        case "max": uiText("Max")
        case "ultra": uiText("Ultra")
        default: raw.capitalized
        }
    }

    static func choice(_ choice: BrowserAIModelChoice, statuses: [BrowserAIProviderID: BrowserAIProviderStatus]) -> String {
        guard choice.provider != .onDevice else { return name(.onDevice) }
        let models = statuses[choice.provider]?.models ?? (choice.provider == .claudeCode ? BrowserAIClaudeLaunch.models : [])
        let model = choice.model.map { id in models.first { $0.id == id }?.displayName ?? id }
        var title = name(choice.provider)
        if let model { title = uiFormat("%@ · %@", title, model) }
        if let effort = choice.effort { title = uiFormat("%@ · %@", title, self.effort(effort)) }
        return title
    }

    /// Why a program's models cannot be picked; nil when they can.
    static func reason(_ state: BrowserAIProviderState?) -> String? {
        switch state {
        case .ready?: nil
        case .signedOut?: uiText("Signed out")
        case .notInstalled?: uiText("Not installed")
        case .unavailable?: uiText("Unavailable")
        case nil: uiText("Checking…")
        }
    }
}
