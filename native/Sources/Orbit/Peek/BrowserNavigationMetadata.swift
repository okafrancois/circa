import Foundation

/// How an engine started the navigation or new target it is asking about, when it can tell.
/// Interim seam (PEEK-R2): CONTRACT-R2 is expected to carry navigation kind, method, body and user
/// gesture in `BrowserNavigationAction` and `BrowserNewSurfaceRequest`; this type then maps from
/// those fields. Unknown metadata never opens a Peek.
struct BrowserNavigationMetadata: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// A link activated by the user.
        case linkActivation
        case formSubmission
        case backForward
        case reload
        case redirect
        /// Script-initiated, typed, programmatic or unclassified.
        case other
    }

    var kind: Kind
    var httpMethod: String?
    var hasBody: Bool

    var isUserLinkActivation: Bool { kind == .linkActivation }

    /// A request that may be cancelled in a tab and loaded again elsewhere without losing anything:
    /// a GET without body. Method, body and opener of anything else must never be replayed.
    var isReplayableGET: Bool { httpMethod?.uppercased() == "GET" && !hasBody }
}

/// Implemented, in the composition root, by engines that can describe the question being asked
/// synchronously during `decidePolicyFor action` or `createSurfaceFor` on `surface`.
@MainActor
protocol BrowserNavigationMetadataSource: AnyObject {
    func pendingNavigationMetadata(for surface: AnyObject) -> BrowserNavigationMetadata?
}
