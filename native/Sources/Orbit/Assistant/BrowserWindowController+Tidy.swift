import AppKit
import SwiftUI
import BrowserCore
import BrowserShell
import UniformTypeIdentifiers

extension BrowserWindowController {
    func showTidyDownload(_ lease: BrowserDownloadCoordinator.RenameLease, original: String) {
        guard let window else { return }
        if let old = tidyDownloadPanel { window.removeChildWindow(old); old.orderOut(nil) }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 76),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.acceptsMouseMovedEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let appearance = window.effectiveAppearance
        let palette = BrowserAssistantPalette(theme: windowShell.theme ?? .default, appearance: appearance)
        panel.appearance = palette.appearance
        panel.contentView = NSHostingView(rootView: TidyDownloadToast(name: lease.url.lastPathComponent, original: original,
            palette: palette, undo: { [weak self] in
                guard let self else { return false }
                return downloads.coordinator.rename(lease, to: original) != nil
            }, dismiss: { [weak self, weak panel, weak window] in
                guard let panel else { return }
                window?.removeChildWindow(panel)
                panel.orderOut(nil)
                if self?.tidyDownloadPanel === panel { self?.tidyDownloadPanel = nil }
            }))
        tidyDownloadPanel = panel
        tidyDownloadSpace = session.organization?.spaceID
        panel.setFrameOrigin(NSPoint(x: window.frame.minX + 24, y: window.frame.minY + 24))
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
    }
}

private struct TidyDownloadToast: View {
    let name: String
    let original: String
    let palette: BrowserAssistantPalette
    let undo: () -> Bool
    let dismiss: () -> Void
    @State private var hovered = false
    @State private var restored = false
    @State private var visible = false
    @State private var entered = false
    @State private var dwellStarted: TimeInterval?
    @State private var remaining = 6.0
    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (name as NSString).pathExtension) ?? .data)).resizable().frame(width: 30, height: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(restored ? uiFormat("Kept “%@”", original) : uiFormat("Renamed to “%@”", name)).contentTransition(.opacity).lineLimit(1)
                Text(restored ? uiText("Original name restored") : uiFormat("was %@", original))
                    .font(Font(BrandTextStyle.ui.font(size: 12))).foregroundStyle(palette.secondary.swiftUI).lineLimit(1)
            }
            Spacer(minLength: 0)
            if !restored {
                Button {
                    if undo() { withAnimation(.timingCurve(1 / 3, 2 / 3, 2 / 3, 1, duration: 0.2)) { restored = true } }
                    else { dismiss() }
                } label: {
                    HStack(spacing: 4) {
                        OrbitIcon.view(sfName: "arrow.uturn.backward", pointSize: 12)
                        Text(uiText("Undo"))
                    }
                    .font(Font(BrandTextStyle.ui.font(size: 12.5, weight: .medium)))
                    .padding(.vertical, 5).padding(.horizontal, 8)
                    .background(palette.hover.swiftUI, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.line.swiftUI, lineWidth: 1))
                }.buttonStyle(.plain).transition(.identity)
            }
        }
        .font(Font(BrandTextStyle.ui.font(size: 13, weight: .medium))).foregroundStyle(palette.ink.swiftUI)
        .padding(.vertical, 10).padding(.horizontal, 12).background(palette.popover.swiftUI, in: RoundedRectangle(cornerRadius: 12))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.popoverEdge.swiftUI, lineWidth: 1))
        .opacity(visible ? 1 : 0).offset(y: entered ? 0 : 12)
        .onHover { inside in
            if inside, !hovered, let start = dwellStarted {
                remaining = max(0, remaining - (ProcessInfo.processInfo.systemUptime - start))
                dwellStarted = nil
            }
            hovered = inside
        }
        .task(id: hovered) {
            if !entered {
                withAnimation(OrbitMotionPreferences.prefersReducedMotion ? nil : .timingCurve(0.19, 1, 0.22, 1, duration: 0.36)) {
                    entered = true; visible = true
                }
            } else if hovered && !visible {
                withAnimation(.timingCurve(1 / 3, 2 / 3, 2 / 3, 1, duration: 0.2)) { visible = true }
            }
            guard !hovered else { return }
            dwellStarted = ProcessInfo.processInfo.systemUptime
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            guard !Task.isCancelled, !hovered else { return }
            dwellStarted = nil; remaining = 0
            withAnimation(.timingCurve(1 / 3, 2 / 3, 2 / 3, 1, duration: 0.2)) { visible = false }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard !Task.isCancelled, !hovered else { return }
            dismiss()
        }
    }
}
