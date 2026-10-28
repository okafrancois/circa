import BrowserCore
import BrowserEngine
import BrowserShell

/// The only place where Peek uses the live surface transfer API. Promotion to a tab and the
/// Split hand-off go through `handOff`.
/// CONTRACT-R2 semantics: a transfer is reversible until the receiver records the surface.
/// - A receiver that refuses synchronously leaves the transfer pending; Peek cancels it in the
///   same turn, which returns the document to Peek's container rebound by `peek.bind`.
/// - A receiver that accepted but fails to record the tab later returns the document to Peek's
///   container (or, if Peek closed meanwhile, to the window's rescue holder); `Outcome.accepted`
///   carries the receiver's adoption so the window can present it again.
@MainActor
enum BrowserPeekTransfer {
    enum Outcome<Value> {
        /// The receiver holds the surface and its delegate; `value` is what it returned.
        case accepted(Value)
        /// Nothing moved: the surface is still owned and bound by Peek.
        case refused
    }

    /// Releases `surface` from Peek and offers it to `receive`, which either accepts the transfer
    /// in this turn or leaves it pending. Acceptance is read from the transfer, never assumed.
    static func handOff<Surface: BrowserEngineSurface, Value>(
        _ surface: Surface,
        from peek: BrowserPeekController<Surface>,
        to receive: (BrowserSurfaceTransfer<Surface>) -> Value
    ) -> Outcome<Value> {
        guard peek.owns(surface),
              let transfer = peek.container.release(surface, profileID: surface.profileID,
                                                    rebind: { [weak peek] in peek?.bind($0) }) else {
            return .refused
        }
        let value = receive(transfer)
        switch transfer.state {
        case .accepted, .completed:
            return .accepted(value)
        case .pending:
            // Back to Peek before the turn ends: no reload, Peek's binding restored.
            transfer.cancel()
            return .refused
        case .returned, .rescued, .stranded:
            return .refused
        }
    }
}
