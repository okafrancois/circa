import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import QuartzCore
import SwiftUI

@MainActor
final class BrowserWritingHelp: ObservableObject {
    struct Context {
        let selection: BrowserAIWritingSelection
        let anchor: NSRect
        let preferences: BrowserAIPreferences
        let choice: BrowserAIModelChoice
        let client: any BrowserAIProviderClient
        let isCurrent: () -> Bool
        let read: () async throws -> BrowserAIWritingSelection?
        let apply: (String, Bool) async throws -> Bool
    }
    enum Action: CaseIterable, Hashable {
        case improve, fix, shorter, translate, ask
        var label: String {
            switch self {
            case .improve: uiText("Improve")
            case .fix: uiText("Fix")
            case .shorter: uiText("Shorter")
            case .translate: uiText("Translate")
            case .ask: uiText("Ask…")
            }
        }
        var instructions: String {
            switch self {
            case .improve: "Improve clarity and flow, preserving meaning and language. Return only the revised text."
            case .fix: "Correct spelling, grammar and punctuation, preserving meaning and language. Return only the corrected text."
            case .shorter: "Make the text concise, preserving its meaning and language. Return only the shortened text."
            case .translate: "Translate the text to the user's preferred language (\(Locale.preferredLanguages.first ?? "en")). Return only the translation."
            case .ask: ""
            }
        }
    }
    var capture: (() async -> Context?)?
    var acceptsInput: ((NSEvent) -> Bool)?
    var ask: ((String) -> Void)?
    var palette: (() -> BrowserAssistantPalette)?
    private weak var window: NSWindow?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var captureTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var validationTask: Task<Void, Never>?
    private let request = BrowserAIHelperRequest()
    private var context: Context?
    private var toolbar: NSPanel?
    private var result: NSPanel?
    @Published private(set) var action: Action = .improve
    private var epoch = UUID()
    private var requestID = UUID()
    @Published private(set) var output = ""
    @Published private(set) var error = ""
    @Published private(set) var running = false
    @Published private(set) var applying = false

    func install(in window: NSWindow) {
        guard monitor == nil else { return }
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown, .keyUp, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            if event.window === self.toolbar || event.window === self.result { return event }
            if event.type == .leftMouseDown { self.dismiss() }
            if event.window === self.window, self.acceptsInput?(event) == true {
                if event.type == .leftMouseUp || event.type == .keyUp { self.schedule() }
                else { self.dismiss() }
            }
            return event
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
    }

    func reconcile() {
        if context?.isCurrent() == false { dismiss() }
    }

    private func schedule() {
        dismiss()
        let token = epoch
        captureTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, let next = await capture?(), epoch == token, next.isCurrent() else { return }
            context = next
            showToolbar()
            // DOM scripts can change the selection without native input. Revalidate the lease
            // while a draft is visible, in addition to the synchronous check at insertion.
            validationTask = Task { [weak self] in
                while let self, !Task.isCancelled, epoch == token {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled, epoch == token else { return }
                    guard next.isCurrent(), let current = try? await next.read(), current.token == next.selection.token else {
                        if epoch == token { dismiss() }
                        return
                    }
                }
            }
        }
    }

    func run(_ action: Action) {
        guard let context, context.isCurrent() else { dismiss(); return }
        if action == .ask {
            let text = context.selection.text
            dismiss()
            ask?(text)
            return
        }
        request.cancel()
        requestTask?.cancel()
        self.action = action
        requestID = UUID()
        output = ""; error = ""; running = true
        showResult()
        let token = epoch, requestToken = requestID
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await request.run(client: context.client, choice: context.choice,
                    instructions: action.instructions, preferences: { context.isCurrent() ? context.preferences : .init() },
                    isCurrent: { context.isCurrent() && self.epoch == token && self.requestID == requestToken }, extract: {
                        guard let current = try await context.read(), current.token == context.selection.token else { throw CancellationError() }
                        return current.text
                    }, outputLimit: 12_000, onText: { [weak self] text in
                        guard let self, epoch == token, requestID == requestToken else { return }
                        output = text
                        resizeResult()
                    })
                guard epoch == token, requestID == requestToken else { return }
                running = false
                resizeResult()
            } catch {
                guard epoch == token, requestID == requestToken else { return }
                running = false
                if error is CancellationError { dismiss(); return }
                self.error = browserAssistantErrorText(error as? BrowserAIError ?? .failed)
                resizeResult()
            }
        }
    }

    func stop() {
        requestID = UUID()
        request.cancel(); requestTask?.cancel(); running = false
        if output.isEmpty { error = uiText("Stopped") }
        resizeResult()
    }

    func retry() { run(action) }

    func apply(insertBelow: Bool) {
        guard !running, !applying, let context, context.isCurrent(), !output.isEmpty else { return }
        applying = true
        let token = epoch, text = output
        Task { [weak self] in
            let applied = (try? await context.apply(text, insertBelow)) ?? false
            guard let self, epoch == token else { return }
            applying = false
            if applied { dismiss(); window?.makeKeyAndOrderFront(nil) }
            else { error = uiText("The selection has changed."); resizeResult() }
        }
    }

    private func makePanel(frame: NSRect, content: AnyView, identifier: String) -> (NSPanel, NSHostingView<AnyView>)? {
        guard let window, let palette = palette?() else { return nil }
        let panel = WritingPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.onEscape = { [weak self] in self?.dismiss() }
        panel.identifier = NSUserInterfaceItemIdentifier(identifier)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.appearance = palette.appearance
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        background.material = .popover; background.blendingMode = .withinWindow; background.state = .active
        background.wantsLayer = true; background.layer?.cornerRadius = 10; background.layer?.masksToBounds = true
        let host = NSHostingView(rootView: AnyView(content.environment(\.assistantPalette, palette)))
        host.frame = background.bounds; host.autoresizingMask = [.width, .height]
        background.layer?.borderWidth = 1
        background.layer?.borderColor = palette.popoverEdge.cgColor
        let tint = NSView(frame: background.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = (NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? palette.popoverSolid : palette.popover).cgColor
        tint.autoresizingMask = [.width, .height]
        background.addSubview(tint)
        background.addSubview(host); panel.contentView = background
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0; opacity.toValue = 1
        let isToolbar = identifier == "writing-toolbar"
        opacity.duration = OrbitMotionPreferences.prefersReducedMotion ? 0.15 : isToolbar ? 0.16 : 0.3
        opacity.timingFunction = OrbitMotionPreferences.prefersReducedMotion ? CAMediaTimingFunction(name: .linear)
            : isToolbar ? CAMediaTimingFunction(controlPoints: 1 / 3, 1, 2 / 3, 1)
            : CAMediaTimingFunction(controlPoints: 0.19, 1, 0.22, 1)
        background.layer?.add(opacity, forKey: "writing-opacity")
        if isToolbar && !OrbitMotionPreferences.prefersReducedMotion {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.97; scale.toValue = 1; scale.duration = 0.16
            scale.timingFunction = CAMediaTimingFunction(controlPoints: 1 / 3, 1, 2 / 3, 1)
            background.layer?.add(scale, forKey: "writing-scale")
        }
        return (panel, host)
    }

    private func frame(height: CGFloat, above: Bool) -> NSRect {
        guard let context, let window else { return .zero }
        let visible = window.screen?.visibleFrame ?? window.frame
        let preferredWidth: CGFloat = above ? toolbarWidth : 420
        let width = min(preferredWidth, window.frame.width - 32, visible.width - 16)
        let x = min(max(context.anchor.minX, visible.minX + 8), visible.maxX - width - 8)
        let y = above ? context.anchor.maxY + 6 : context.anchor.minY - height - 8
        return NSRect(x: x, y: min(max(y, visible.minY + 8), visible.maxY - height - 8), width: width, height: height)
    }

    private var toolbarWidth: CGFloat {
        NSHostingView(rootView: BrowserWritingToolbar(model: self)).fittingSize.width
    }

    private func showToolbar() {
        toolbar = makePanel(frame: frame(height: 34, above: true),
                            content: AnyView(BrowserWritingToolbar(model: self)), identifier: "writing-toolbar")?.0
    }
    private func showResult() {
        if result == nil {
            let pair = makePanel(frame: frame(height: 0, above: false),
                                 content: AnyView(BrowserWritingResult(model: self)), identifier: "writing-result")
            result = pair?.0
        }
        resizeResult()
    }
    private func resizeResult() {
        let text = output.isEmpty ? error : output
        let width = max(100, frame(height: 100, above: false).width - 24)
        let height = min(280, max(80, ceil((text as NSString).boundingRect(with: NSSize(width: width, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: BrandTextStyle.ui.font(size: 13)]).height) + 58))
        guard let result else { return }
        NSAnimationContext.runAnimationGroup { animation in
            animation.duration = OrbitMotionPreferences.prefersReducedMotion ? 0.15 : 0.3
            animation.timingFunction = OrbitMotionPreferences.prefersReducedMotion ? CAMediaTimingFunction(name: .linear)
                : CAMediaTimingFunction(controlPoints: 0.19, 1, 0.22, 1)
            result.animator().setFrame(frame(height: height, above: false), display: true)
        }
    }

    func dismiss() {
        epoch = UUID()
        requestID = UUID()
        captureTask?.cancel(); captureTask = nil
        validationTask?.cancel(); validationTask = nil
        requestTask?.cancel(); requestTask = nil; request.cancel()
        for panel in [toolbar, result].compactMap({ $0 }) { window?.removeChildWindow(panel); panel.orderOut(nil); panel.close() }
        toolbar = nil; result = nil; context = nil
        running = false; applying = false; output = ""; error = ""
    }
    func close() {
        dismiss()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}

private final class WritingPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

private struct BrowserWritingToolbar: View {
    @ObservedObject var model: BrowserWritingHelp
    @Environment(\.assistantPalette) private var palette
    var body: some View {
        HStack(spacing: 2) {
            ForEach(BrowserWritingHelp.Action.allCases, id: \.self) { action in
                Button { model.run(action) } label: {
                    HStack(spacing: 5) {
                        if action == .improve { OrbitIcon.view(sfName: "sparkles", pointSize: 13).frame(width: 13, height: 13) }
                        Text(action.label).fixedSize()
                    }.padding(.horizontal, 9).frame(height: 26)
                }.buttonStyle(WritingActionStyle(active: model.action == action && (model.running || !model.output.isEmpty)))
                    .accessibilityIdentifier("writing-\(action)")
            }
        }.font(Font(BrandTextStyle.ui.font(size: 12, weight: .medium)))
            .foregroundStyle(palette.ink.swiftUI).padding(4)
    }
}

private struct BrowserWritingResult: View {
    @ObservedObject var model: BrowserWritingHelp
    @Environment(\.assistantPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if model.running && model.output.isEmpty { BrowserAssistantThinkingView() }
                    if !model.output.isEmpty { Text(model.output).textSelection(.enabled) }
                    if !model.error.isEmpty { Text(model.error) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                if model.running { Button(uiText("Stop")) { model.stop() } }
                else {
                    Button(uiText("Replace")) { model.apply(insertBelow: false) }
                        .disabled(model.output.isEmpty || model.applying).accessibilityIdentifier("writing-replace").buttonStyle(WritingResultActionStyle(primary: true))
                    Button(uiText("Insert Below")) { model.apply(insertBelow: true) }
                        .disabled(model.output.isEmpty || model.applying).accessibilityIdentifier("writing-insert")
                    Button(uiText("Retry")) { model.retry() }.disabled(model.applying)
                }
            }.buttonStyle(WritingResultActionStyle())
        }.font(Font(BrandTextStyle.ui.font(size: 13))).foregroundStyle(palette.ink.swiftUI)
            .padding(12).accessibilityIdentifier("writing-draft")
    }
}

private struct WritingActionStyle: ButtonStyle {
    var active = false
    @Environment(\.assistantPalette) private var palette
    func makeBody(configuration: Configuration) -> some View {
        WritingActionBody(configuration: configuration, palette: palette, active: active)
    }
    private struct WritingActionBody: View {
        let configuration: ButtonStyleConfiguration
        let palette: BrowserAssistantPalette
        let active: Bool
        @State private var hovered = false
        var body: some View {
            configuration.label.background((configuration.isPressed ? palette.press : hovered || active ? palette.hover : .clear).swiftUI,
                                           in: RoundedRectangle(cornerRadius: 6))
                .onHover { hovered = $0 }
        }
    }
}

private struct WritingResultActionStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, primary: primary)
    }
    private struct Styled: View {
        let configuration: Configuration
        let primary: Bool
        @Environment(\.assistantPalette) private var palette
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false
        var body: some View {
            configuration.label.font(Font(BrandTextStyle.ui.font(size: 12.5, weight: .medium)))
                .padding(.horizontal, 12).frame(height: 26)
                .foregroundStyle((primary ? palette.onStrong : palette.ink).swiftUI)
                .background((primary ? palette.strong : hovered ? palette.hover : palette.wash).swiftUI,
                            in: RoundedRectangle(cornerRadius: 7))
                .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
                .onHover { hovered = $0 }
        }
    }
}
