import AppKit
import BrowserCore
import BrowserShell
import SwiftUI

/// The assistant's intentional button family: hover and pressed states come from the Space palette and
/// keyboard focus stays on the macOS accent.
struct BrowserAssistantButtonStyle: ButtonStyle {
    enum Kind {
        /// 30 pt square icon button.
        case icon
        /// Control with no rest fill, such as the model pill.
        case quiet(radius: CGFloat)
        /// Outlined action such as a source or a suggestion.
        case outlined(radius: CGFloat)
        /// A row in a popover.
        case option(selected: Bool)
    }
    var kind: Kind
    var active = false
    /// The arrow-key cursor of a popover list, drawn like keyboard focus.
    var cursor = false

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, kind: kind, active: active, cursor: cursor)
    }

    private struct Styled: View {
        let configuration: Configuration
        let kind: Kind
        let active: Bool
        let cursor: Bool
        @Environment(\.assistantPalette) private var palette
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @State private var hovering = false

        private var radius: CGFloat {
            switch kind {
            case .icon, .option: 8
            case .quiet(let radius), .outlined(let radius): radius
            }
        }
        private var fill: Color {
            if configuration.isPressed { return palette.press.swiftUI }
            if case .option(true) = kind { return palette.wash.swiftUI }
            if active { return palette.wash.swiftUI }
            return hovering && enabled ? palette.hover.swiftUI : .clear
        }
        private var outlined: Bool { if case .outlined = kind { true } else { false } }

        var body: some View {
            configuration.label
                .contentShape(RoundedRectangle(cornerRadius: radius))
                .background(fill, in: RoundedRectangle(cornerRadius: radius))
                .overlay {
                    if outlined { RoundedRectangle(cornerRadius: radius).strokeBorder(palette.line.swiftUI, lineWidth: 1) }
                }
                .overlay {
                    if focused || cursor {
                        RoundedRectangle(cornerRadius: radius).strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 2)
                    }
                }
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovering = $0 }
        }
    }
}

/// A 30 pt circle: Space accent while sending is possible, reading ink while it would stop.
struct BrowserAssistantSendButtonStyle: ButtonStyle {
    var running: Bool
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, running: running) }

    private struct Styled: View {
        let configuration: Configuration
        let running: Bool
        @Environment(\.assistantPalette) private var palette
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused

        private var fill: Color {
            if running { return palette.ink.swiftUI }
            return enabled ? palette.strong.swiftUI : palette.hover.swiftUI
        }
        private var glyph: Color {
            if running { return (palette.surfaces.first ?? .clear).swiftUI }
            return enabled ? palette.onStrong.swiftUI : palette.tertiary.swiftUI
        }
        var body: some View {
            configuration.label.foregroundStyle(glyph).frame(width: 30, height: 30)
                .background(fill, in: Circle())
                .overlay { if configuration.isPressed { Circle().fill(palette.press.swiftUI) } }
                .overlay { if focused { Circle().strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 2) } }
                .contentShape(Circle())
        }
    }
}

/// Real provider artwork; on-device work keeps its system symbol. Ink follows the surface behind it.
struct BrowserAssistantProviderMark: View {
    let provider: BrowserAIProviderID
    var size: CGFloat = 18
    @Environment(\.assistantPalette) private var palette

    var body: some View {
        Group {
            if provider == .onDevice {
                OrbitIcon.view(sfName: "laptopcomputer", pointSize: 16).foregroundStyle(palette.ink.swiftUI)
            } else if let mark = BrowserSettingsAIMark.image(provider, isDark: palette.isDark) {
                Image(nsImage: mark).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .padding(size / 18)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Numbered citation used in a source chip, matching the inline form.
struct BrowserAssistantCitationNumber: View {
    let number: Int
    @Environment(\.assistantPalette) private var palette
    var body: some View {
        Text(verbatim: String(number)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
            .foregroundStyle(palette.accentInk.swiftUI).padding(.horizontal, 4)
            .frame(minWidth: 17, minHeight: 17)
            .background(palette.wash.swiftUI, in: RoundedRectangle(cornerRadius: 5))
    }
}

/// Wrapping row of chips, bounded by the composer width.
struct BrowserAssistantFlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        return CGSize(width: proposal.width ?? rows.map(\.maxX).max() ?? 0, height: rows.last?.maxY ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, width: bounds.width)
        for (subview, frame) in zip(subviews, rows) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }
    private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        var result: [CGRect] = []
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let chip = CGSize(width: min(size.width, width), height: size.height)
            if x > 0, x + chip.width > width { x = 0; y += row + spacing; row = 0 }
            result.append(CGRect(origin: CGPoint(x: x, y: y), size: chip))
            x += chip.width + spacing
            row = max(row, chip.height)
        }
        return result
    }
}

/// Window-scoped key handling that does not depend on which SwiftUI view holds first responder.
struct BrowserAssistantKeyMonitor: NSViewRepresentable {
    var handler: (NSEvent) -> Bool
    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) { view.handler = handler }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    final class MonitorView: NSView {
        var handler: ((NSEvent) -> Bool)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window, self.handler?(event) == true else { return event }
                return nil
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

enum BrowserAssistantKey {
    static let escape: UInt16 = 53, left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    static let returnKey: UInt16 = 36, keypadEnter: UInt16 = 76
}
