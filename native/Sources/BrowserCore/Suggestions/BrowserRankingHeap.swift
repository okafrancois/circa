/// A best-first heap: linear construction, then only the requested prefix is ordered.
/// The caller supplies a total order, including its existing stable tie breaker.
public struct BrowserRankingHeap<Element> {
    private var elements: [Element]
    private let precedes: (Element, Element) -> Bool
    public init(_ elements: [Element], by precedes: @escaping (Element, Element) -> Bool) {
        self.elements = elements
        self.precedes = precedes
        if elements.count > 1 {
            for index in stride(from: elements.count / 2 - 1, through: 0, by: -1) { siftDown(index) }
        }
    }
    public mutating func popFirst() -> Element? {
        guard !elements.isEmpty else { return nil }
        if elements.count == 1 { return elements.removeLast() }
        let first = elements[0]
        elements[0] = elements.removeLast()
        siftDown(0)
        return first
    }
    private mutating func siftDown(_ start: Int) {
        var parent = start
        while parent * 2 + 1 < elements.count {
            var child = parent * 2 + 1
            if child + 1 < elements.count, precedes(elements[child + 1], elements[child]) { child += 1 }
            if !precedes(elements[child], elements[parent]) { return }
            elements.swapAt(parent, child)
            parent = child
        }
    }
}
