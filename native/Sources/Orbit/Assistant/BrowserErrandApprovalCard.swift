import AppKit
import BrowserCore
import BrowserShell
import QuartzCore
import SwiftUI

@MainActor final class BrowserErrandApprovalCard: NSView {
    let content: NSHostingView<AnyView>
    private(set) var exiting = false
    override var isFlipped: Bool { true }
    init(approval: BrowserAIErrandApproval, palette: BrowserAssistantPalette,
         stop: @escaping () -> Void, allow: @escaping () -> Void) {
        content = NSHostingView(rootView: AnyView(BrowserErrandApprovalView(approval: approval, palette: palette, stop: stop, allow: allow)))
        super.init(frame: .zero)
        identifier = .init("errand-approval")
        appearance = palette.appearance
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 18; layer?.shadowOffset = NSSize(width: 0, height: -8)
        OrbitFloatingMaterial.install(in: self, radius: 12)
        content.sizingOptions = [.intrinsicContentSize]
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor)])
        setAccessibilityRole(.group)
        setAccessibilityLabel(uiText("Allow this action?"))
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if exiting {
            let local = superview.map { convert(point, from: $0) } ?? point
            return bounds.contains(local) ? self : nil
        }
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    func enter() {
        guard let layer else { return }
        let reduced = OrbitMotionPreferences.prefersReducedMotion
        let curve = reduced ? CAMediaTimingFunction(name: .linear) : CAMediaTimingFunction(controlPoints: 0.19, 1, 0.22, 1)
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0; opacity.toValue = 1; opacity.duration = reduced ? 0.15 : 0.36; opacity.timingFunction = curve
        layer.add(opacity, forKey: "errand-entry-opacity")
        if !reduced {
            let move = CABasicAnimation(keyPath: "transform.translation.y")
            move.fromValue = 12; move.toValue = 0; move.duration = 0.36; move.timingFunction = curve
            layer.add(move, forKey: "errand-entry-position")
        }
    }
    func dismiss(animated: Bool) {
        guard !exiting else { return }
        exiting = true
        guard animated, let layer, window?.isVisible == true else { removeFromSuperview(); return }
        let reduced = OrbitMotionPreferences.prefersReducedMotion
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated { self?.removeFromSuperview() } }
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = layer.presentation()?.opacity ?? 1; opacity.toValue = 0
        opacity.duration = reduced ? 0.15 : 0.20
        opacity.timingFunction = reduced ? .init(name: .linear) : .init(controlPoints: 1.0 / 3, 0, 2.0 / 3, 0)
        layer.opacity = 0; layer.add(opacity, forKey: "errand-exit-opacity")
        if !reduced {
            let move = CABasicAnimation(keyPath: "transform.translation.y")
            move.fromValue = layer.presentation()?.value(forKeyPath: "transform.translation.y") ?? 0
            move.toValue = 6; move.duration = 0.20; move.timingFunction = opacity.timingFunction
            layer.add(move, forKey: "errand-exit-position")
        }
        CATransaction.commit()
    }
}

private struct BrowserErrandApprovalView: View {
    let approval: BrowserAIErrandApproval
    let palette: BrowserAssistantPalette
    let stop: () -> Void
    let allow: () -> Void
    private var title: String {
        switch approval.action {
        case .open: uiText("Open this page?")
        case .type: uiText("Enter this text?")
        case .click: approval.target?.submitsForm == true ? uiText("Submit this form?") : uiText("Click this target?")
        case .finish: uiText("Summary · draft")
        }
    }
    private var showsLock: Bool {
        guard case .click = approval.action else { return false }
        return (approval.target?.label ?? "").range(of: "pay|send|delete|purchase|buy|checkout|publish|envoyer|payer|supprimer|acheter", options: [.regularExpression, .caseInsensitive]) != nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                OrbitIcon.view(sfName: "hand.raised", pointSize: 16)
                    .frame(width: 30, height: 30).background(palette.hover.swiftUI, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Font(BrandTextStyle.ui.font(size: 13, weight: .semibold)))
                    ScrollView {
                        Text(detail).font(Font(BrandTextStyle.ui.font(size: 13)))
                            .foregroundStyle(OrbitFloatingMaterial.secondary.swiftUI)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: detail.count > 300 ? 110 : 60).fixedSize(horizontal: false, vertical: true)
                }
            }
            if showsLock {
                HStack(spacing: 5) {
                    OrbitIcon.view(sfName: "lock.fill", pointSize: 12)
                    Text(uiText("Sending, paying and deleting always ask."))
                }.font(Font(BrandTextStyle.ui.font(size: 11.5))).foregroundStyle(OrbitFloatingMaterial.secondary.swiftUI).padding(.top, 8)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(action: stop) { Text(uiText("Stop")).frame(minWidth: 80).frame(height: 32) }
                    .buttonStyle(BrowserAssistantButtonStyle(kind: .outlined(radius: 6))).accessibilityIdentifier("errand-stop")
                Button(action: allow) { Text(uiText("Allow Once")).frame(minWidth: 80).frame(height: 32)
                    .foregroundStyle(palette.onStrong.swiftUI).background(palette.strong.swiftUI, in: RoundedRectangle(cornerRadius: 6)) }
                    .buttonStyle(.plain).accessibilityIdentifier("errand-allow-once")
            }.font(Font(BrandTextStyle.ui.font(size: 13))).padding(.top, 16)
        }.padding(20).foregroundStyle(OrbitFloatingMaterial.body.swiftUI)
            .environment(\.assistantPalette, palette)
    }
    private var detail: String {
        if case .open(let url) = approval.action { return url.absoluteString }
        let host = approval.page?.url.host ?? "", label = approval.target?.label ?? ""
        if case .type(_, _, let value) = approval.action { return host + "\n" + label + "\n" + value }
        return host + "\n" + label + (approval.target?.destination.map { "\n" + $0.absoluteString } ?? "")
    }
}
