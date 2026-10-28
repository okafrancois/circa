import BrowserCore
import BrowserEngine
import BrowserShell

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
