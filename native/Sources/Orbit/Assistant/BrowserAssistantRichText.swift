import AppKit
import BrowserCore
import BrowserShell
import SwiftUI

/// Reading structure of an answer. Model links stay plain text: the only links in an answer are
/// citations that passed validation against the snapshot sent with the turn.
enum BrowserAssistantRichText {
    struct Run: Equatable {
        var text: String
        var bold = false
        var italic = false
        var code = false
        var citation: BrowserAICitation?
    }
    enum Block: Equatable {
        case paragraph([Run])
        case heading([Run])
        case bullet([Run])
        case ordered(Int, [Run])
        case code(String)
    }

    private static let open: Character = "\u{E000}", close: Character = "\u{E001}"

    static func blocks(_ message: BrowserAIMessage) -> [Block] {
        var citations: [BrowserAICitation] = []
        var source = ""
        for segment in BrowserAICitation.segments(message) {
            switch segment {
            case .text(let text): source += text.filter { $0 != open && $0 != close }
            case .citation(let citation):
                source += String(open) + String(citations.count) + String(close)
                citations.append(citation)
            }
        }
        return blocks(source, citations: citations)
    }

    private static func blocks(_ source: String, citations: [BrowserAICitation]) -> [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var fence: [String]?
        func flush() {
            guard !paragraph.isEmpty else { return }
            result.append(.paragraph(inline(paragraph.joined(separator: "\n"), citations)))
            paragraph = []
        }
        for raw in source.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let open = fence { result.append(.code(open.joined(separator: "\n"))); fence = nil }
                else { flush(); fence = [] }
            } else if fence != nil {
                fence?.append(raw)
            } else if line.isEmpty {
                flush()
            } else if let heading = line.wholeMatch(of: /#{1,6}\s+(.+)/) {
                flush(); result.append(.heading(inline(String(heading.1), citations)))
            } else if let bullet = line.wholeMatch(of: /[-*•]\s+(.+)/) {
                flush(); result.append(.bullet(inline(String(bullet.1), citations)))
            } else if let ordered = line.wholeMatch(of: /(\d{1,4})[.)]\s+(.+)/) {
                flush(); result.append(.ordered(Int(ordered.1) ?? 1, inline(String(ordered.2), citations)))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        if let fence, !fence.isEmpty { result.append(.code(fence.joined(separator: "\n"))) }
        return result
    }

    private static func inline(_ text: String, _ citations: [BrowserAICitation]) -> [Run] {
        let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        guard let parsed else { return split(Run(text: text), citations) }
        return parsed.runs.flatMap { run -> [Run] in
            let intent = run.inlinePresentationIntent ?? []
            return split(Run(text: String(parsed[run.range].characters), bold: intent.contains(.stronglyEmphasized),
                             italic: intent.contains(.emphasized), code: intent.contains(.code)), citations)
        }
    }

    private static func split(_ run: Run, _ citations: [BrowserAICitation]) -> [Run] {
        var result: [Run] = []
        var rest = Substring(run.text)
        while let start = rest.firstIndex(of: open), let end = rest[start...].firstIndex(of: close) {
            if start > rest.startIndex {
                var before = run
                before.text = String(rest[..<start])
                result.append(before)
            }
            if let index = Int(rest[rest.index(after: start)..<end]), citations.indices.contains(index) {
                result.append(Run(text: "", citation: citations[index]))
            }
            rest = rest[rest.index(after: end)...]
        }
        if !rest.isEmpty {
            var tail = run
            tail.text = String(rest)
            result.append(tail)
        }
        return result
    }

    // MARK: Attributed text

    static let citationKey = NSAttributedString.Key("BrowserAssistant.citation")
    static let inlineCodeBackgroundKey = NSAttributedString.Key("BrowserAssistant.inlineCodeBackground")
    private static let lineHeight: CGFloat = 21, bodySize: CGFloat = 14

    @MainActor
    static func attributed(_ blocks: [Block], palette: BrowserAssistantPalette, activeCitation: String?,
                           hoveredCitation: String?, hoverFractions: [String: CGFloat] = [:]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = BrandTextStyle.ui.font(size: bodySize, weight: .regular)
        func style(indent: CGFloat = 0, spacing: CGFloat = 6) -> NSParagraphStyle {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
            paragraph.paragraphSpacing = spacing
            paragraph.headIndent = indent
            paragraph.tabStops = indent > 0 ? [NSTextTab(textAlignment: .left, location: indent)] : []
            return paragraph
        }
        func baseline(_ font: NSFont) -> CGFloat { (lineHeight - (font.ascender - font.descender)) / 2 }
        func append(_ runs: [Run], paragraph: NSParagraphStyle, font base: NSFont = body) {
            for run in runs {
                if let citation = run.citation {
                    let attachment = BrowserAssistantCitationAttachment(number: citation.number, palette: palette,
                        highlighted: citation.id == activeCitation || citation.id == hoveredCitation,
                        fillFraction: citation.id == activeCitation ? 1 : hoverFractions[citation.id])
                    let pill = NSMutableAttributedString(attachment: attachment)
                    pill.addAttributes([citationKey: citation.id, .paragraphStyle: paragraph,
                                        .baselineOffset: baseline(base)], range: NSRange(location: 0, length: pill.length))
                    result.append(pill)
                    continue
                }
                var font = base
                if run.bold { font = BrandTextStyle.ui.font(size: base.pointSize, weight: .semibold) }
                if run.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: palette.ink,
                                                                 .paragraphStyle: paragraph, .baselineOffset: baseline(font)]
                if run.code {
                    let code = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
                    attributes[.font] = code
                    attributes[.baselineOffset] = baseline(code)
                    attributes[inlineCodeBackgroundKey] = palette.hover
                }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        }
        for (index, block) in blocks.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n", attributes: [.font: body])) }
            switch block {
            case .paragraph(let runs): append(runs, paragraph: style())
            case .heading(let runs): append(runs, paragraph: style(), font: BrandTextStyle.ui.font(size: bodySize, weight: .semibold))
            case .bullet(let runs), .ordered(_, let runs):
                let paragraph = style(indent: 16)
                var marker = "•"
                if case .ordered(let number, _) = block { marker = String(number) + "." }
                result.append(NSAttributedString(string: marker + "\t", attributes: [
                    .font: body, .foregroundColor: palette.tertiary, .paragraphStyle: paragraph, .baselineOffset: baseline(body)]))
                append(runs, paragraph: paragraph)
            case .code(let code):
                let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
                result.append(NSAttributedString(string: code, attributes: [
                    .font: font, .foregroundColor: palette.ink, .backgroundColor: palette.hover,
                    .paragraphStyle: style(), .baselineOffset: baseline(font)]))
            }
        }
        return result
    }

    /// The range that just arrived, when the new text continues what was already shown.
    static func arrivingRange(old: String, new: String) -> NSRange? {
        let oldText = old as NSString, newText = new as NSString
        guard newText.length > oldText.length, newText.hasPrefix(old) else { return nil }
        return NSRange(location: oldText.length, length: newText.length - oldText.length)
    }
}

/// A 17 pt rounded citation pill, drawn from the palette, that flows inside the text.
final class BrowserAssistantCitationAttachment: NSTextAttachment {
    @MainActor
    init(number: Int, palette: BrowserAssistantPalette, highlighted: Bool, fillFraction: CGFloat? = nil) {
        super.init(data: nil, ofType: nil)
        let label = NSAttributedString(string: String(number), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: highlighted ? palette.onStrong : palette.accentInk])
        let size = NSSize(width: max(17, ceil(label.size().width) + 8), height: 17)
        let fraction = min(1, max(0, fillFraction ?? (highlighted ? 1 : 0)))
        let fill = palette.wash.blended(withFraction: fraction, of: palette.strong) ?? palette.wash
        // Drawn with a small margin so neighbouring glyphs keep their distance from the pill.
        let canvas = NSSize(width: size.width + 2, height: size.height)
        image = NSImage(size: canvas, flipped: false) { _ in
            fill.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 0, width: size.width, height: size.height), xRadius: 5, yRadius: 5).fill()
            let text = label.size()
            label.draw(at: NSPoint(x: 1 + (size.width - text.width) / 2, y: (size.height - text.height) / 2))
            return true
        }
        bounds = NSRect(x: 0, y: -2.5, width: canvas.width, height: canvas.height)
    }
    required init?(coder: NSCoder) { nil }
}

/// Selectable answer text with real inline citation pills. Provenance stays out of the clipboard.
struct BrowserAssistantAnswerText: NSViewRepresentable {
    let message: BrowserAIMessage
    var open: (BrowserAICitation) -> Void
    var activeCitation: String?
    @Environment(\.assistantPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var systemReduced

    func makeNSView(context: Context) -> TextView {
        let view = TextView(usingTextLayoutManager: false)
        view.textContainer?.replaceLayoutManager(BrowserAssistantAnswerLayoutManager())
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.importsGraphics = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.setAccessibilityIdentifier("assistant-answer")
        return view
    }

    func updateNSView(_ view: TextView, context: Context) {
        let citations = Dictionary(BrowserAICitation.parse(message).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        view.citations = citations
        view.open = open
        view.activeCitation = activeCitation
        view.palette = palette
        view.selectedTextAttributes = [.backgroundColor: palette.wash, .foregroundColor: palette.ink]
        view.reduced = systemReduced || OrbitMotionPreferences.prefersReducedMotion
        view.update(blocks: BrowserAssistantRichText.blocks(message), animated: message.state == .streaming)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: TextView, context: Context) -> CGSize? {
        let width = proposal.width.map { $0.isFinite ? $0 : 340 } ?? 340
        return CGSize(width: width, height: view.height(forWidth: width))
    }

    @MainActor
    final class TextView: NSTextView {
        var citations: [String: BrowserAICitation] = [:]
        var open: ((BrowserAICitation) -> Void)?
        var palette: BrowserAssistantPalette?
        var reduced = false
        var activeCitation: String? { didSet { if activeCitation != oldValue { render(animated: false) } } }
        private var hoveredCitation: String? { didSet { if hoveredCitation != oldValue { animateCitationHover() } } }
        private var hoverFractions: [String: CGFloat] = [:]
        private var hoverAnimation: Task<Void, Never>?
        private var blocks: [BrowserAssistantRichText.Block] = []
        private var arriving: [(range: NSRange, start: CFTimeInterval)] = []
        private var fade: Task<Void, Never>?
        private var trackingZone: NSTrackingArea?

        func update(blocks: [BrowserAssistantRichText.Block], animated: Bool) {
            self.blocks = blocks
            render(animated: animated)
        }

        private func render(animated: Bool) {
            guard let palette, let storage = textStorage else { return }
            let next = BrowserAssistantRichText.attributed(blocks, palette: palette, activeCitation: activeCitation,
                                                           hoveredCitation: hoveredCitation, hoverFractions: hoverFractions)
            if storage.isEqual(to: next) { return }
            let previous = storage.string
            let selection = selectedRanges
            storage.setAttributedString(next)
            selectedRanges = selection.map { value in
                let range = value.rangeValue
                return NSValue(range: range.location + range.length <= storage.length ? range : NSRange(location: storage.length, length: 0))
            }
            if animated, let range = BrowserAssistantRichText.arrivingRange(old: previous, new: storage.string) {
                arriving.append((range, CACurrentMediaTime()))
            }
            applyFade()
        }

        /// Arriving text fades in with no layout change, 0.12 s linear (0.15 s under Reduce Motion).
        private func applyFade() {
            guard let storage = textStorage else { return }
            let duration = reduced ? 0.15 : 0.12
            let now = CACurrentMediaTime()
            arriving.removeAll { now - $0.start >= duration }
            for item in arriving where item.range.location + item.range.length <= storage.length {
                let alpha = CGFloat((now - item.start) / duration)
                storage.enumerateAttribute(.foregroundColor, in: item.range) { value, range, _ in
                    guard let color = value as? NSColor else { return }
                    storage.addAttribute(.foregroundColor, value: color.withAlphaComponent(alpha), range: range)
                }
            }
            guard !arriving.isEmpty, fade == nil else { return }
            fade = Task { [weak self] in
                while let self, !Task.isCancelled, !self.arriving.isEmpty {
                    try? await Task.sleep(for: .milliseconds(16))
                    guard !Task.isCancelled else { return }
                    self.render(animated: false)
                }
                self?.fade = nil
            }
        }

        func height(forWidth width: CGFloat) -> CGFloat {
            guard let container = textContainer, let manager = layoutManager else { return 0 }
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            manager.ensureLayout(for: container)
            return ceil(manager.usedRect(for: container).height)
        }

        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

        // The transcript owns scrolling; this text view only owns selection and links.
        override func scrollWheel(with event: NSEvent) {
            nextResponder?.scrollWheel(with: event)
        }

        private func animateCitationHover() {
            hoverAnimation?.cancel()
            let initial = hoverFractions
            let target = hoveredCitation
            let ids = Set(initial.keys).union(target.map { [$0] } ?? [])
            let start = CACurrentMediaTime()
            let duration = reduced ? 0.15 : 0.12
            hoverAnimation = Task { [weak self] in
                while let self, !Task.isCancelled {
                    let time = min(1, (CACurrentMediaTime() - start) / duration)
                    let progress = reduced ? time : BrowserAssistantMotion.citationHoverProgress(time)
                    for id in ids {
                        let from = initial[id] ?? 0
                        let to: CGFloat = id == target ? 1 : 0
                        hoverFractions[id] = from + (to - from) * progress
                    }
                    render(animated: false)
                    if time >= 1 {
                        hoverFractions = target.map { [$0: 1] } ?? [:]
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
        }

        private func citation(at point: NSPoint) -> String? {
            guard let manager = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
            var fraction: CGFloat = 0
            let glyph = manager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
            guard manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point) else { return nil }
            let character = manager.characterIndexForGlyph(at: glyph)
            return storage.attribute(BrowserAssistantRichText.citationKey, at: character, effectiveRange: nil) as? String
        }

        override func mouseDown(with event: NSEvent) {
            if let id = citation(at: convert(event.locationInWindow, from: nil)), let citation = citations[id] {
                open?(citation)
                return
            }
            super.mouseDown(with: event)
        }

        override func mouseMoved(with event: NSEvent) {
            hoveredCitation = citation(at: convert(event.locationInWindow, from: nil))
            if hoveredCitation != nil { NSCursor.pointingHand.set() } else { super.mouseMoved(with: event) }
        }
        override func mouseExited(with event: NSEvent) {
            hoveredCitation = nil
            super.mouseExited(with: event)
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingZone { removeTrackingArea(trackingZone) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingZone = area
        }

        /// Citation pills are not text: copying a selection keeps only what the reader sees as words.
        override func copy(_ sender: Any?) {
            guard let storage = textStorage else { return }
            let text = selectedRanges.map { storage.attributedSubstring(from: $0.rangeValue).string }.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text.replacingOccurrences(of: "\u{FFFC}", with: ""), forType: .string)
        }
    }
}

/// Draw inline code behind the selectable glyphs, including runs that wrap across lines.
final class BrowserAssistantAnswerLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage {
            let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            storage.enumerateAttribute(BrowserAssistantRichText.inlineCodeBackgroundKey, in: characters) { value, range, _ in
                guard let color = value as? NSColor else { return }
                let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                guard glyphs.length > 0, let container = self.textContainer(forGlyphAt: glyphs.location, effectiveRange: nil) else { return }
                color.setFill()
                self.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                             in: container) { rect, _ in
                    let background = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -4, dy: 0)
                    NSBezierPath(roundedRect: background, xRadius: 4, yRadius: 4).fill()
                }
            }
        }
        // AppKit paints the selection above code backgrounds and below its glyphs.
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}
