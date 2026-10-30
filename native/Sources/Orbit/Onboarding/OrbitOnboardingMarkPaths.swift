import AppKit
import BrowserShell

/// Reads stroked paths from the swappable vector resource. No mark geometry lives in the view.
final class OrbitOnboardingMarkPaths {
    struct Stroke {
        let path: CGPath
        let color: NSColor
        let width: CGFloat
    }
    struct State {
        var transform = CGAffineTransform.identity
        var color = NSColor.black
        var width: CGFloat = 1
    }
    var strokes: [Stroke] = []
    var path = CGMutablePath()
    var state = State()
    var stack: [State] = []
    static func read() -> (CGRect, [Stroke])? {
        guard let url = BrandFonts.markURL, let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1),
              let table = CGPDFOperatorTableCreate() else { return nil }
        let reader = OrbitOnboardingMarkPaths()
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            let r = Unmanaged<OrbitOnboardingMarkPaths>.fromOpaque(info!).takeUnretainedValue(); r.stack.append(r.state)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let r = Unmanaged<OrbitOnboardingMarkPaths>.fromOpaque(info!).takeUnretainedValue(); if let s = r.stack.popLast() { r.state = s }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            let r = Unmanaged<OrbitOnboardingMarkPaths>.fromOpaque(info!).takeUnretainedValue()
            let n = OrbitOnboardingMarkPaths.numbers(scanner, 6)
            r.state.transform = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]).concatenating(r.state.transform)
        }
        CGPDFOperatorTableSetCallback(table, "RG") { scanner, info in
            let r = Unmanaged<OrbitOnboardingMarkPaths>.fromOpaque(info!).takeUnretainedValue(); let n = OrbitOnboardingMarkPaths.numbers(scanner, 3)
            r.state.color = NSColor(srgbRed: n[0], green: n[1], blue: n[2], alpha: 1)
        }
        for op in ["SC", "SCN"] {
            CGPDFOperatorTableSetCallback(table, op) { scanner, info in
                let r = Unmanaged<OrbitOnboardingMarkPaths>.fromOpaque(info!).takeUnretainedValue()
                let n = OrbitOnboardingMarkPaths.numbers(scanner, 3)
                r.state.color = NSColor(srgbRed: n[0], green: n[1], blue: n[2], alpha: 1)
            }
        }
        CGPDFOperatorTableSetCallback(table, "G") { scanner, info in
            let r = Unmanaged<OrbitOnboardingMarkPaths>.fromOpaque(info!).takeUnretainedValue(); r.state.color = NSColor(white: OrbitOnboardingMarkPaths.numbers(scanner, 1)[0], alpha: 1)
        }
        CGPDFOperatorTableSetCallback(table, "w") { scanner, info in
            let r = Unmanaged<OrbitOnboardingMarkPaths>.fromOpaque(info!).takeUnretainedValue(); r.state.width = OrbitOnboardingMarkPaths.numbers(scanner, 1)[0]
        }
        CGPDFOperatorTableSetCallback(table, "m") { scanner, info in
            let r = Unmanaged<OrbitOnboardingMarkPaths>.fromOpaque(info!).takeUnretainedValue(); let n = OrbitOnboardingMarkPaths.numbers(scanner, 2)
            r.path.move(to: CGPoint(x: n[0], y: n[1]), transform: r.state.transform)
        }
        CGPDFOperatorTableSetCallback(table, "l") { scanner, info in
            let r = Unmanaged<OrbitOnboardingMarkPaths>.fromOpaque(info!).takeUnretainedValue(); let n = OrbitOnboardingMarkPaths.numbers(scanner, 2)
            r.path.addLine(to: CGPoint(x: n[0], y: n[1]), transform: r.state.transform)
        }
        CGPDFOperatorTableSetCallback(table, "c") { scanner, info in
            let r = Unmanaged<OrbitOnboardingMarkPaths>.fromOpaque(info!).takeUnretainedValue(); let n = OrbitOnboardingMarkPaths.numbers(scanner, 6)
            r.path.addCurve(to: CGPoint(x: n[4], y: n[5]), control1: CGPoint(x: n[0], y: n[1]), control2: CGPoint(x: n[2], y: n[3]), transform: r.state.transform)
        }
        CGPDFOperatorTableSetCallback(table, "h") { _, info in
            Unmanaged<OrbitOnboardingMarkPaths>.fromOpaque(info!).takeUnretainedValue().path.closeSubpath()
        }
        CGPDFOperatorTableSetCallback(table, "S") { _, info in
            let r = Unmanaged<OrbitOnboardingMarkPaths>.fromOpaque(info!).takeUnretainedValue()
            r.strokes.append(.init(path: r.path.copy()!, color: r.state.color, width: r.state.width))
            r.path = CGMutablePath()
        }
        let stream = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(reader).toOpaque())
        guard CGPDFScannerScan(scanner), !reader.strokes.isEmpty else { return nil }
        return (page.getBoxRect(.mediaBox), reader.strokes)
    }
    private static func numbers(_ scanner: CGPDFScannerRef?, _ count: Int) -> [CGFloat] {
        var values = [CGFloat](repeating: 0, count: count)
        for i in (0..<count).reversed() { var n: CGPDFReal = 0; _ = CGPDFScannerPopNumber(scanner!, &n); values[i] = n }
        return values
    }
}
