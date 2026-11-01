import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

/// Find in page: bar placement, input routing to the document shown when typing, focus return.
/// The searched page is `pageCommandSurface()`: the selected tab, or a Peek document with focus.
extension BrowserWindowController {
    func installFindBar(in root: NSView) {
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true
        let preferredFindWidth = findBar.widthAnchor.constraint(equalToConstant: 400)
        preferredFindWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([preferredFindWidth, findBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 42)])
        placeFindBar(in: root, over: contentCard)
        findBar.onQueryChange = { [weak self] query, matchCase in
            guard let self else { return }
            submitFind(query, matchCase: matchCase, optionsRevision: findBar.pendingOptionsRevision)
        }
        findBar.onAsk = { [weak self] in self?.submitFindBarAction { $0.askInFind() } }
        findBar.onNext = { [weak self] in self?.submitFindBarAction { $0.findSession.next() } }
        findBar.onPrevious = { [weak self] in self?.submitFindBarAction { $0.findSession.previous() } }
        findBar.onClose = { [weak self] in self?.submitFindBarAction { $0.closeFind() } }
    }

    /// Puts the find bar at the top trailing corner of the page it searches (`anchor`), above the
    /// other subviews of `container`: the content card, or a Peek card (`placeFindBar(for:)`).
    func placeFindBar(in container: NSView, over anchor: NSView) {
        guard findBar.superview !== container else { return }
        findBar.removeFromSuperview()
        if container === window?.contentView {
            container.addSubview(findBar, positioned: .below, relativeTo: library.view)
        } else {
            container.addSubview(findBar)
        }
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: anchor.topAnchor, constant: 8),
            findBar.trailingAnchor.constraint(equalTo: anchor.trailingAnchor, constant: -8),
            findBar.widthAnchor.constraint(lessThanOrEqualTo: anchor.widthAnchor, constant: -16)
        ])
    }

    func showFind() {
        guard acceptsCommands else { return }
        recordExplicitInput()
        session.performWindowAction { [weak self] in
            guard let self, let surface = pageCommandSurface() else { return }
            if !isEditingFind {
                focusBeforeFind = window?.firstResponder === addressField.currentEditor()
                    && addressField.currentEditor() != nil ? addressField : window?.firstResponder
            }
            findSession.show(on: surface)
            renderFind()
            findBar.focusQuery()
        }
    }

    /// Widget input belongs to the document displayed when the user typed, even if routing waits.
    func submitFind(_ query: String, matchCase: Bool = false, optionsRevision: UUID? = nil) {
        cancelFindAnswer()
        submitFindBarAction {
            $0.findSession.submit(query, matchCase: matchCase)
            $0.findBar.acknowledgeOptions(optionsRevision)
            $0.renderFind()
        }
    }

    private func submitFindBarAction(_ action: @escaping @MainActor (BrowserWindowController) -> Void) {
        guard let owner = findOwner else { return }
        let generation = displayedFindDocumentGeneration
        submitInput { [weak owner] controller in
            controller.session.performWindowAction { [weak controller, weak owner] in
                guard let controller, let owner, controller.pageCommandSurface() === owner,
                      controller.findOwner === owner, owner.findDocumentGeneration == generation else { return }
                action(controller)
            }
        }
    }

    func findNext() { performFindCommand { $0.next() } }
    func findPrevious() { performFindCommand { $0.previous() } }

    private func performFindCommand(_ action: @escaping @MainActor (BrowserFindSession<Surface>) -> Void) {
        guard acceptsCommands, !library.isPresented || peek.isPresented else { return }
        session.performWindowAction { [weak self] in
            guard let self, !library.isPresented || peek.isPresented, let surface = pageCommandSurface() else { return }
            findSession.select(surface)
            action(findSession)
        }
    }

    func closeFind() {
        cancelFindAnswer()
        shouldReturnFindFocus = isEditingFind
        findSession.close()
        shouldReturnFindFocus = false
    }

    private var isEditingFind: Bool {
        guard let bar = findBarStorage else { return false }
        return (bar.searchField.currentEditor() != nil && window?.firstResponder === bar.searchField.currentEditor())
            || (window?.firstResponder as? NSView)?.isDescendant(of: bar) == true
    }

    func returnFocusAfterFind(on surface: Surface) {
        guard shouldReturnFindFocus, pageCommandSurface() === surface else { return }
        let responder = focusBeforeFind
        focusBeforeFind = nil
        if let view = responder as? NSView, view.window === window,
           !view.isHiddenOrHasHiddenAncestor, !view.isDescendant(of: surface.hostView),
           window?.makeFirstResponder(view) == true { return }
        surface.focusDocument()
    }

    func renderFind() {
        guard let state = findSession.state, let surface = pageCommandSurface() else {
            cancelFindAnswer()
            findBarStorage?.isHidden = true
            findOwner = nil
            displayedFindDocumentGeneration = 0
            return
        }
        guard state.isVisible || findBarStorage != nil else { return }
        let ownerChanged = findOwner !== surface || displayedFindDocumentGeneration != surface.findDocumentGeneration
        if ownerChanged || !state.isVisible { cancelFindAnswer() }
        placeFindBar(for: surface)
        findOwner = surface
        displayedFindDocumentGeneration = surface.findDocumentGeneration
        findBar.isHidden = !state.isVisible
        findBar.offerAsk(findAskChoice != nil && BrowserFindQuestion.isQuestion(state.query))
        let status: String
        if state.isPending { status = uiText("Searching…") }
        else if state.error != nil { status = uiText("Find Unavailable") }
        else if state.hasExactCount, let count = state.count {
            if count == 0 { status = uiText("No Results") }
            else if let ordinal = state.activeOrdinal, ordinal > 0 { status = uiFormat("%ld/%ld", ordinal, count) }
            else { status = uiFormat("%ld results", count) }
        } else if let found = state.matchFound { status = found ? uiText("Found") : uiText("No Results") }
        else { status = "" }
        findBar.render(query: state.query, matchCase: state.matchCase, status: status,
                       searching: state.isPending, canNavigate: !state.query.isEmpty && state.error == nil,
                       replaceEditing: ownerChanged)
    }
}
