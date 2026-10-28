import BrowserShell
import Foundation
import Testing

private final class WeakFindObject<Object: AnyObject> {
    weak var value: Object?
    init(_ object: Object?) { value = object }
}

@MainActor
private final class FindSurface: BrowserFindSurface {
    typealias Callback = @MainActor (BrowserFindUpdate) -> Void

    let profileID = UUID()
    var currentURL: URL? { URL(string: "https://synthetic.test/document") }
    var findDocumentGeneration: UInt64 = 1
    var requests: [BrowserFindRequest] = []
    var callbacks: [Callback] = []
    var stops: [Bool] = []
    var events: [String] = []
    var disposalCount = 0
    var nativeDepth = 0
    var maximumNativeDepth = 0
    var onPerform: ((BrowserFindRequest) -> Void)?
    var onStop: ((Bool) -> Void)?

    func performFind(_ request: BrowserFindRequest, update: @escaping Callback) {
        nativeDepth += 1
        maximumNativeDepth = max(maximumNativeDepth, nativeDepth)
        defer { nativeDepth -= 1; events.append("end:\(request.query)") }
        requests.append(request)
        callbacks.append(update)
        events.append("find:\(request.query)")
        onPerform?(request)
    }

    func stopFinding(clearSelection: Bool) {
        nativeDepth += 1
        maximumNativeDepth = max(maximumNativeDepth, nativeDepth)
        defer { nativeDepth -= 1 }
        stops.append(clearSelection)
        events.append("stop")
        onStop?(clearSelection)
    }

    func dispose() { disposalCount += 1 }

    func report(
        _ index: Int = 0, found: Bool, count: Int? = nil, ordinal: Int? = nil,
        final: Bool = true, token: UUID? = nil, generation: UInt64? = nil,
        error: BrowserFindError? = nil
    ) {
        let request = requests[index]
        callbacks[index](BrowserFindUpdate(
            token: token ?? request.token,
            documentGeneration: generation ?? request.documentGeneration,
            matchFound: found, count: count, activeOrdinal: ordinal, final: final, error: error
        ))
    }
}

@Suite("Engine-independent find coordination")
@MainActor
struct BrowserFindSessionTests {
    @Test("Pending, unknown final and exact final counts are distinct")
    func resultKnowledge() throws {
        let surface = FindSurface()
        let session = BrowserFindSession<FindSurface>()
        #expect(session.state == nil)
        session.show(on: surface)
        #expect(session.state?.isVisible == true)
        #expect(session.state?.isPending == false)
        #expect(session.state?.matchFound == nil)
        session.submit("needle")
        #expect(session.state?.isPending == true)
        #expect(session.state?.count == nil)
        #expect(session.state?.isFinal == false)
        #expect(surface.requests[0].selectMatch)
        surface.report(found: true)
        let unknown = try #require(session.state)
        #expect(!unknown.isPending && unknown.isFinal)
        #expect(unknown.matchFound == true && unknown.count == nil && unknown.activeOrdinal == nil)
        #expect(!unknown.hasExactCount)
        session.next()
        #expect(surface.requests[0].token != surface.requests[1].token)
        surface.report(1, found: true, count: 8, ordinal: 3)
        #expect(session.state?.count == 8 && session.state?.activeOrdinal == 3)
        #expect(session.state?.hasExactCount == true)
        session.previous()
        surface.report(2, found: false)
        #expect(session.state?.matchFound == false)
        #expect(session.state?.count == nil && session.state?.hasExactCount == false)
    }

    @Test("Partial totals are provisional and reports after final are ignored")
    func multipartResults() {
        let surface = FindSurface()
        let session = BrowserFindSession<FindSurface>()
        session.show(on: surface)
        session.submit("needle")
        surface.report(found: true, count: 2, ordinal: 0, final: false)
        #expect(session.state?.isPending == true && session.state?.count == 2)
        #expect(session.state?.hasExactCount == false)
        surface.report(found: true, count: 7, ordinal: 4)
        let final = session.state
        var publications = 0
        session.onChange = { publications += 1 }
        surface.report(found: true, count: 3, ordinal: 1, final: false)
        surface.report(found: false, count: 0, ordinal: 0)
        surface.report(found: false, error: .unsupportedOperation)
        #expect(session.state == final)
        #expect(publications == 0)
    }

    @Test("Count-only results preserve ordinal zero and zero matches stay exact")
    func countOnlyAndZero() {
        let surface = FindSurface()
        let session = BrowserFindSession<FindSurface>()
        session.show(on: surface)
        session.submit("needle", selectMatch: false)
        #expect(!surface.requests[0].selectMatch)
        surface.report(found: true, count: 5, ordinal: 0)
        #expect(session.state?.count == 5 && session.state?.activeOrdinal == 0)
        #expect(session.state?.hasExactCount == true)
        session.next()
        #expect(surface.requests[1].selectMatch)
        surface.report(1, found: true, count: 5, ordinal: 1)
        session.submit("absent")
        surface.report(2, found: false, count: 0, ordinal: 0)
        #expect(session.state?.count == 0 && session.state?.activeOrdinal == 0)
        #expect(session.state?.matchFound == false && session.state?.hasExactCount == true)
    }

    @Test("Unsupported count-only is a terminal error without fabricated no-match data")
    func unsupportedCountOnly() {
        let surface = FindSurface()
        let session = BrowserFindSession<FindSurface>()
        session.show(on: surface)
        surface.onPerform = { _ in surface.report(found: false, error: .unsupportedOperation) }
        session.submit("needle", selectMatch: false)
        #expect(session.state?.error == .unsupportedOperation)
        #expect(session.state?.isPending == false && session.state?.isFinal == true)
        #expect(session.state?.matchFound == nil && session.state?.count == nil)
        #expect(session.state?.activeOrdinal == nil && session.state?.hasExactCount == false)
    }

    @Test("Synchronous engine reports see an installed operation context")
    func synchronousReport() {
        let surface = FindSurface()
        let session = BrowserFindSession<FindSurface>()
        session.show(on: surface)
        surface.onPerform = { request in
            #expect(session.state?.query == request.query)
            #expect(session.state?.documentGeneration == request.documentGeneration)
            #expect(session.state?.isPending == true)
            surface.report(found: true, count: 9, ordinal: 2)
        }
        session.submit("needle", matchCase: true)
        #expect(session.state?.count == 9 && session.state?.activeOrdinal == 2)
        #expect(session.state?.isPending == false)
        #expect(surface.requests[0].matchCase)
    }

    @Test("Profiles and inactive surfaces retain their own queries without selection effects")
    func surfaceIsolation() {
        let first = FindSurface()
        let second = FindSurface()
        let session = BrowserFindSession<FindSurface>()
        #expect(first.profileID != second.profileID && first.currentURL == second.currentURL)
        session.show(on: first)
        session.submit("first", matchCase: true)
        session.select(second)
        #expect(session.state?.query == "" && session.state?.isVisible == false)
        #expect(session.state?.matchCase == false && session.state?.count == nil)
        #expect(second.requests.isEmpty && second.stops.isEmpty)
        var publications = 0
        session.onChange = { publications += 1 }
        first.report(found: true, count: 6, ordinal: 2)
        #expect(publications == 0)
        #expect(session.state(for: first)?.count == 6)
        #expect(session.state?.count == nil)
        session.show()
        session.submit("second")
        second.report(found: true)
        let calls = first.requests.count + second.requests.count
        let stops = first.stops.count + second.stops.count
        session.select(first)
        #expect(session.state?.query == "first" && session.state?.matchCase == true)
        #expect(session.state?.count == 6 && session.state?.isVisible == true)
        session.select(second)
        #expect(session.state?.query == "second" && session.state?.count == nil)
        #expect(first.requests.count + second.requests.count == calls)
        #expect(first.stops.count + second.stops.count == stops)
    }

    @Test("Identical queries on different surfaces never authorize foreign callbacks")
    func foreignTokens() {
        let first = FindSurface()
        let second = FindSurface()
        let session = BrowserFindSession<FindSurface>()
        session.show(on: first)
        session.submit("same")
        session.show(on: second)
        session.submit("same")
        #expect(first.requests[0].token != second.requests[0].token)
        first.report(found: true, count: 100, ordinal: 1, token: second.requests[0].token)
        second.report(found: true, count: 100, ordinal: 1, token: first.requests[0].token)
        #expect(session.state(for: first)?.isPending == true)
        #expect(session.state(for: second)?.isPending == true)
        #expect(session.state(for: first)?.count == nil && session.state(for: second)?.count == nil)
        first.report(found: true, count: 2, ordinal: 1)
        second.report(found: true, count: 3, ordinal: 2)
        #expect(session.state(for: first)?.count == 2 && session.state?.count == 3)
    }

    @Test("Late asynchronous query results and stop reports cannot revive the previous operation")
    func queryReplacement() async {
        let surface = FindSurface()
        let session = BrowserFindSession<FindSurface>()
        session.show(on: surface)
        session.submit("old")
        session.next()
        let late = Task { @MainActor in surface.report(found: true, count: 99, ordinal: 3) }
        surface.onStop = { _ in
            #expect(session.state?.query == "new" && session.state?.isPending == true)
            surface.report(found: true, count: 88, ordinal: 2)
        }
        session.submit("new")
        #expect(surface.stops == [true])
        #expect(surface.requests.map(\.query) == ["old", "new"])
        #expect(session.state?.count == nil)
        await late.value
        #expect(session.state?.query == "new" && session.state?.count == nil)
        surface.report(1, found: true, count: 1, ordinal: 1)
        #expect(session.state?.count == 1 && surface.requests.count == 2)
    }

    @Test("Pending navigation coalesces to one latest direction and preserves the native cursor")
    func pendingNavigation() {
        let surface = FindSurface()
        let session = BrowserFindSession<FindSurface>()
        session.show(on: surface)
        session.submit("needle")
        session.next()
        session.previous()
        session.next()
        session.previous()
        #expect(surface.requests.count == 1)
        surface.report(found: true, count: 2, ordinal: 1, final: false)
        #expect(surface.requests.count == 1)
        surface.report(found: true, count: 4, ordinal: 1)
        #expect(surface.requests.count == 2 && surface.requests[1].forward == false)
        #expect(surface.requests[1].selectMatch)
        #expect(surface.requests[0].token != surface.requests[1].token)
        #expect(surface.stops.isEmpty)
        #expect(session.state?.isPending == true && session.state?.count == nil)
        surface.report(1, found: true, count: 4, ordinal: 4)
        #expect(session.state?.activeOrdinal == 4)
        session.next()
        #expect(surface.requests.count == 3 && surface.requests[2].forward)
        #expect(surface.stops.isEmpty)
    }

    @Test("A queued movement remains attached to its original inactive surface")
    func pendingMovementDoesNotTargetNewSelection() {
        let first = FindSurface()
        let second = FindSurface()
        let session = BrowserFindSession<FindSurface>()
        session.show(on: first)
        session.submit("needle")
        session.previous()
        session.show(on: second)
        var publications = 0
        session.onChange = { publications += 1 }
        first.report(found: true, count: 3, ordinal: 1)
        #expect(first.requests.count == 2 && !first.requests[1].forward)
        #expect(second.requests.isEmpty && publications == 0)
        #expect(session.state?.query == "" && session.state(for: first)?.isPending == true)
    }

    @Test("Reentrant perform reports serialize a replacement after the native call returns")
    func reentrantPerformReplacement() {
        let surface = FindSurface()
        let session = BrowserFindSession<FindSurface>()
        session.show(on: surface)
        surface.onPerform = { request in
            if request.query == "old" {
                surface.report(found: true, count: 3, ordinal: 1, final: false)
                session.submit("new")
                surface.report(found: true, count: 9, ordinal: 1)
            } else {
                surface.report(1, found: true, count: 2, ordinal: 1)
            }
        }
        session.submit("old")
        #expect(surface.events == ["find:old", "end:old", "stop", "find:new", "end:new"])
        #expect(surface.maximumNativeDepth == 1)
        #expect(session.state?.query == "new" && session.state?.count == 2)
    }

    @Test("A query replaced during stop suppresses the intermediate native dispatch")
    func reentrantStopReplacement() {
        let surface = FindSurface()
        let session = BrowserFindSession<FindSurface>()
        session.show(on: surface)
        session.submit("old")
        surface.onStop = { _ in
            surface.onStop = nil
            session.submit("replacement")
            surface.report(found: true, count: 100, ordinal: 1)
        }
        session.submit("intermediate")
        #expect(surface.requests.map(\.query) == ["old", "replacement"])
        #expect(surface.maximumNativeDepth == 1 && surface.stops == [true])
        #expect(session.state?.query == "replacement" && session.state?.count == nil)
    }

    @Test("A UI observer can replace pending intent before any obsolete native call")
    func reentrantObserverReplacement() {
        let surface = FindSurface()
        let session = BrowserFindSession<FindSurface>()
        session.show(on: surface)
        session.onChange = {
            if session.state?.query == "discarded" { session.submit("kept") }
        }
        session.submit("discarded")
        #expect(surface.requests.map(\.query) == ["kept"])
        #expect(surface.stops.isEmpty)
    }

    @Test("Synchronous completion drains a queued direction without nesting engine calls")
    func synchronousQueuedMovement() {
        let surface = FindSurface()
        let session = BrowserFindSession<FindSurface>()
        session.show(on: surface)
        surface.onPerform = { _ in
            let index = surface.requests.count - 1
            if index == 0 { session.previous() }
            surface.report(index, found: true, count: 4, ordinal: index == 0 ? 1 : 4)
        }
        session.submit("needle")
        #expect(surface.requests.count == 2 && !surface.requests[1].forward)
        #expect(surface.maximumNativeDepth == 1 && surface.stops.isEmpty)
        #expect(session.state?.activeOrdinal == 4 && session.state?.isPending == false)
    }

    @Test("Bar closure revokes reports before stop and returns focus to the exact surface")
    func closeAndFocus() {
        let surface = FindSurface()
        let session = BrowserFindSession<FindSurface>()
        session.show(on: surface)
        session.submit("retained")
        session.next()
        var focused: FindSurface?
        session.onFocusReturn = { focused = $0 }
        surface.onStop = { _ in
            #expect(session.state?.isVisible == false && session.state?.isPending == false)
            surface.report(found: true, count: 20, ordinal: 1)
        }
        session.close(clearSelection: false)
        #expect(surface.stops == [false] && focused === surface)
        #expect(session.state?.query == "retained" && session.state?.count == nil)
        session.show()
        #expect(surface.requests.count == 1 && session.state?.isVisible == true)
        session.next()
        #expect(surface.requests.count == 2 && surface.requests[1].query == "retained")
        #expect(surface.disposalCount == 0)
    }

    @Test("Focus return is revoked by a reentrant profile selection")
    func focusDoesNotEscapeSelection() {
        let first = FindSurface()
        let second = FindSurface()
        let session = BrowserFindSession<FindSurface>()
        session.show(on: first)
        session.submit("needle")
        var focusCount = 0
        session.onFocusReturn = { _ in focusCount += 1 }
        first.onStop = { _ in session.show(on: second) }
        session.close()
        #expect(focusCount == 0 && session.selectedSurface === second)
        #expect(session.state(for: first)?.isVisible == false)
        #expect(second.requests.isEmpty)
    }

    @Test("Closing during perform suppresses late synchronous results and queued movement")
    func reentrantClose() {
        let surface = FindSurface()
        let session = BrowserFindSession<FindSurface>()
        session.show(on: surface)
        surface.onPerform = { _ in
            session.next()
            session.close(returnFocus: false)
            surface.report(found: true, count: 20, ordinal: 1)
        }
        session.submit("needle")
        #expect(surface.requests.count == 1 && surface.stops == [true])
        #expect(surface.maximumNativeDepth == 1)
        #expect(session.state?.isVisible == false && session.state?.count == nil)
    }

    @Test("Reentrant Cmd-G during bar closure preserves the required cancellation")
    func closeThenReentrantMovement() {
        let surface = FindSurface()
        let session = BrowserFindSession<FindSurface>()
        session.show(on: surface)
        session.submit("needle")
        var didMove = false
        session.onChange = {
            if !didMove && session.state?.isVisible == false && session.state?.isPending == false {
                didMove = true
                session.next()
            }
        }
        session.close(returnFocus: false)
        #expect(surface.requests.count == 2 && surface.stops == [true])
        #expect(surface.events == ["find:needle", "end:needle", "stop", "find:needle", "end:needle"])
        #expect(session.state?.isPending == true && session.state?.isVisible == false)
        surface.report(found: true, count: 100, ordinal: 1)
        #expect(session.state?.count == nil)
        surface.report(1, found: true, count: 2, ordinal: 1)
        #expect(session.state?.count == 2)
    }

    @Test("Selecting after unnotified navigation defers cancellation until explicit movement")
    func documentSynchronizationPreservesCancellation() {
        let surface = FindSurface()
        let session = BrowserFindSession<FindSurface>()
        session.show(on: surface)
        session.submit("needle")
        surface.findDocumentGeneration += 1
        session.select(surface)
        #expect(surface.stops.isEmpty && surface.requests.count == 1)
        #expect(session.state?.documentGeneration == 2 && session.state?.isPending == false)
        session.next()
        #expect(surface.stops == [true] && surface.requests.count == 2)
        #expect(surface.requests[1].documentGeneration == 2)
    }

    @Test("Resubmitting the same query refreshes a living document with a new token")
    func livingDocumentRefresh() {
        let surface = FindSurface()
        let session = BrowserFindSession<FindSurface>()
        session.show(on: surface)
        session.submit("needle")
        surface.report(found: true, count: 8, ordinal: 2)
        session.submit("needle")
        #expect(surface.stops == [true] && surface.requests.count == 2)
        #expect(surface.requests[0].token != surface.requests[1].token)
        #expect(surface.requests[0].documentGeneration == surface.requests[1].documentGeneration)
        #expect(session.state?.isPending == true && session.state?.count == nil)
        surface.report(found: true, count: 8, ordinal: 3)
        #expect(session.state?.isPending == true && session.state?.count == nil)
        surface.report(1, found: true, count: 2, ordinal: 1)
        #expect(session.state?.count == 2 && session.state?.hasExactCount == true)
    }

    @Test("Same-URL document replacement invalidates results and never implicitly reruns")
    func documentReplacement() {
        let surface = FindSurface()
        let session = BrowserFindSession<FindSurface>()
        session.show(on: surface)
        session.submit("needle")
        session.next()
        surface.findDocumentGeneration += 1
        #expect(session.state?.isPending == false && session.state?.count == nil)
        surface.report(found: true, count: 20, ordinal: 1)
        #expect(session.state?.count == nil)
        surface.onStop = { _ in surface.report(found: true, count: 30, ordinal: 2) }
        session.documentDidChange(on: surface)
        #expect(surface.requests.count == 1 && surface.stops == [true])
        #expect(session.state?.query == "needle" && session.state?.isVisible == true)
        #expect(session.state?.documentGeneration == 2 && session.state?.isPending == false)
        session.select(surface)
        #expect(surface.requests.count == 1)
        session.submit("needle")
        #expect(surface.requests[1].documentGeneration == 2)
        surface.report(1, found: true, count: 1, ordinal: 1, generation: 1)
        #expect(session.state?.count == nil)
        surface.report(1, found: true, count: 1, ordinal: 1)
        #expect(session.state?.count == 1)
    }

    @Test("Navigation between publication and dispatch prevents searching the wrong document")
    func documentChangesBeforeDispatch() {
        let surface = FindSurface()
        let session = BrowserFindSession<FindSurface>()
        session.show(on: surface)
        session.onChange = {
            if session.state?.isPending == true { surface.findDocumentGeneration += 1 }
        }
        session.submit("needle")
        #expect(surface.requests.isEmpty)
        #expect(session.state?.documentGeneration == 2 && session.state?.isPending == false)
    }

    @Test("Retirement erases state before stop and prevents reentrant readoption")
    func retirement() {
        let surface = FindSurface()
        let session = BrowserFindSession<FindSurface>()
        session.show(on: surface)
        session.submit("private synthetic query")
        surface.onStop = { _ in
            #expect(session.state(for: surface) == nil && session.selectedSurface == nil)
            session.show(on: surface)
            session.submit("must not dispatch")
            surface.report(found: true, count: 20, ordinal: 1)
        }
        session.retire(surface)
        session.select(surface)
        session.show(on: surface)
        #expect(session.state == nil && session.state(for: surface) == nil)
        #expect(surface.requests.count == 1 && surface.stops == [true])
        #expect(surface.disposalCount == 0)
    }

    @Test("Window shutdown revokes all surfaces before any stop callback")
    func windowShutdown() {
        let first = FindSurface()
        let second = FindSurface()
        let session = BrowserFindSession<FindSurface>()
        session.show(on: first)
        session.submit("one")
        session.show(on: second)
        session.submit("two")
        let stopAction: (Bool) -> Void = { _ in
            #expect(session.isClosed && session.selectedSurface == nil)
            #expect(session.state(for: first) == nil && session.state(for: second) == nil)
            first.report(found: true, count: 4, ordinal: 1)
            second.report(found: true, count: 5, ordinal: 1)
            session.show(on: first)
            session.submit("revoked")
        }
        first.onStop = stopAction
        second.onStop = stopAction
        session.shutdown()
        session.shutdown()
        session.next()
        session.previous()
        session.documentDidChange(on: first)
        session.select(second)
        #expect(first.requests.count == 1 && second.requests.count == 1)
        #expect(first.stops == [true] && second.stops == [true])
        #expect(session.state == nil)
    }

    @Test("Session entries and engine callbacks do not own surfaces or the session")
    func weakLifetimes() throws {
        var surface: FindSurface? = FindSurface()
        var session: BrowserFindSession<FindSurface>? = BrowserFindSession()
        let weakSurface = WeakFindObject(surface)
        let weakSession = WeakFindObject(session)
        session?.show(on: try #require(surface))
        session?.submit("synthetic")
        let callback = try #require(surface?.callbacks.first)
        let request = try #require(surface?.requests.first)
        surface = nil
        #expect(weakSurface.value == nil && session?.selectedSurface == nil)
        #expect(session?.state == nil)
        callback(BrowserFindUpdate(
            token: request.token, documentGeneration: request.documentGeneration,
            matchFound: true, count: 40, activeOrdinal: 1, final: true
        ))
        session = nil
        #expect(weakSession.value == nil)
        callback(BrowserFindUpdate(
            token: request.token, documentGeneration: request.documentGeneration,
            matchFound: false, final: true
        ))
    }

    @Test("Malformed totals, ordinals and error envelopes leave an operation pending")
    func malformedReports() {
        let surface = FindSurface()
        let session = BrowserFindSession<FindSurface>()
        session.show(on: surface)
        session.submit("needle")
        let pending = session.state
        let malformed: [(Bool, Int?, Int?, Bool, BrowserFindError?)] = [
            (true, -1, nil, true, nil), (true, 2, -1, true, nil),
            (true, 2, 3, true, nil), (true, 0, 0, true, nil),
            (false, 2, 0, true, nil), (false, nil, 1, true, nil),
            (false, nil, nil, false, .unsupportedOperation),
            (true, nil, nil, true, .unsupportedOperation),
            (false, 0, 0, true, .unsupportedOperation)
        ]
        for (found, count, ordinal, final, error) in malformed {
            surface.report(found: found, count: count, ordinal: ordinal, final: final, error: error)
            #expect(session.state == pending)
        }
        surface.report(found: true, count: 2, ordinal: 1)
        #expect(session.state?.hasExactCount == true)
        session.submit("needle", selectMatch: false)
        surface.report(1, found: true, count: 2, ordinal: 1)
        #expect(session.state?.isPending == true && session.state?.count == nil)
        surface.report(1, found: true, count: 2, ordinal: 0)
        #expect(session.state?.hasExactCount == true && session.state?.activeOrdinal == 0)
    }

    @Test("Regressing multipart deliveries cannot replace newer partial knowledge")
    func regressingPartials() {
        let surface = FindSurface()
        let session = BrowserFindSession<FindSurface>()
        session.show(on: surface)
        session.submit("needle")
        surface.report(found: true, count: 4, ordinal: 2, final: false)
        let partial = session.state
        surface.report(found: true, count: 2, ordinal: 1, final: false)
        #expect(session.state == partial)
        surface.report(found: true, ordinal: 2, final: false)
        #expect(session.state == partial)
        surface.report(found: true, count: 4, ordinal: 0, final: false)
        #expect(session.state == partial)
        surface.report(found: false)
        #expect(session.state == partial)
        // A final report that cannot establish a total must not promote a provisional total.
        surface.report(found: true)
        #expect(session.state?.isFinal == true && session.state?.count == nil)
        #expect(session.state?.hasExactCount == false)
    }

    @Test("Clearing cancels without requiring a stop report and whitespace is a literal query")
    func emptyAndWhitespaceQueries() {
        let surface = FindSurface()
        let session = BrowserFindSession<FindSurface>()
        session.show(on: surface)
        session.submit("needle")
        session.next()
        session.submit("")
        #expect(surface.requests.count == 1 && surface.stops == [true])
        #expect(session.state?.query == "" && session.state?.isPending == false)
        surface.report(found: true, count: 20, ordinal: 1)
        session.next()
        session.previous()
        #expect(surface.requests.count == 1 && session.state?.count == nil)
        session.submit("  ", matchCase: true)
        #expect(surface.requests[1].query == "  " && surface.requests[1].matchCase)
    }
}
