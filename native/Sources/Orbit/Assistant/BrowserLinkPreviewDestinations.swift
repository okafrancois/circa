import Darwin
import Foundation

/// Network destinations a link preview may reach: public internet hosts only. Loopback,
/// link-local, private (RFC 1918, ULA, CGNAT), multicast, reserved and local-only names are
/// refused before the request, after DNS resolution, and against the address the
/// connection actually reached.
struct BrowserLinkPreviewDestinations: Sendable {
    /// Numeric addresses for a host name, or nil when resolution fails.
    typealias Resolver = @Sendable (String) -> [String]?

    let resolve: Resolver
    /// Endpoints ("host:port", IPv6 in brackets) treated as public. Tests only: a loopback
    /// fixture stands in for a web server.
    let trustedEndpoints: Set<String>
    /// Endpoints trusted when checking the address a connection reached; defaults to
    /// `trustedEndpoints`. Tests only.
    let trustedConnections: Set<String>

    init(resolve: @escaping Resolver = BrowserLinkPreviewDestinations.systemResolve, trustedEndpoints: Set<String> = [],
         trustedConnections: Set<String>? = nil) {
        self.resolve = resolve
        self.trustedEndpoints = trustedEndpoints
        self.trustedConnections = trustedConnections ?? trustedEndpoints
    }

    static let publicInternet = BrowserLinkPreviewDestinations()

    /// Literal check of a URL's host, before any resolution.
    func permitsLiteral(_ url: URL) -> Bool {
        guard let host = Self.normalizedHost(url) else { return false }
        if Self.isTrusted(host: host, port: Self.port(url), in: trustedEndpoints) { return true }
        return Self.isPublicHost(host)
    }

    /// Full check: literal host, then every resolved address. Blocking; call off the main thread.
    func permitsResolved(_ url: URL) -> Bool {
        guard let host = Self.normalizedHost(url) else { return false }
        if Self.isTrusted(host: host, port: Self.port(url), in: trustedEndpoints) { return true }
        guard Self.isPublicHost(host) else { return false }
        if Self.literalAddress(host) != nil { return true }
        guard let addresses = resolve(host), !addresses.isEmpty else { return false }
        return addresses.allSatisfy(Self.isPublicAddress)
    }

    /// The address a connection actually reached.
    func permits(remoteAddress: String, port: Int?) -> Bool {
        let address = Self.stripScope(remoteAddress)
        if Self.isTrusted(host: address, port: port, in: trustedConnections) { return true }
        return Self.isPublicAddress(address)
    }

    private static func isTrusted(host: String, port: Int?, in endpoints: Set<String>) -> Bool {
        guard !endpoints.isEmpty, let port else { return false }
        let name = host.contains(":") ? "[\(host)]" : host
        return endpoints.contains("\(name):\(port)")
    }

    private static func port(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil)
    }

    static func normalizedHost(_ url: URL) -> String? {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : stripScope(host)
    }

    private static func stripScope(_ address: String) -> String {
        guard let percent = address.firstIndex(of: "%") else { return address }
        return String(address[..<percent])
    }

    /// Names that can only mean this machine or the local network, and literal addresses
    /// outside the public internet. Single-label names resolve through local search domains.
    static func isPublicHost(_ host: String) -> Bool {
        let host = stripScope(host.lowercased())
        if literalAddress(host) != nil { return isPublicAddress(host) }
        guard host.contains("."), !host.hasPrefix("."), !host.contains("..") else { return false }
        for suffix in ["localhost", "local", "home.arpa", "internal", "lan"] {
            if host == suffix || host.hasSuffix("." + suffix) { return false }
        }
        return true
    }

    enum Address: Equatable { case v4([UInt8]), v6([UInt8]) }

    /// Parses dotted, legacy (inet_aton) IPv4 forms and IPv6 literals.
    static func literalAddress(_ text: String) -> Address? {
        let text = stripScope(text)
        var v6 = in6_addr()
        if text.contains(":") {
            guard inet_pton(AF_INET6, text, &v6) == 1 else { return nil }
            return .v6(withUnsafeBytes(of: &v6) { Array($0) })
        }
        // inet_aton also accepts "127.1", "0x7f.1" and "2130706433", which some resolvers honor.
        guard text.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == "x" || $0 == "X" }) else { return nil }
        var v4 = in_addr()
        guard inet_aton(text, &v4) == 1 else { return nil }
        return .v4(withUnsafeBytes(of: &v4) { Array($0) })
    }

    static func isPublicAddress(_ text: String) -> Bool {
        switch literalAddress(text) {
        case .v4(let bytes)?: return isPublicV4(bytes)
        case .v6(let bytes)?: return isPublicV6(bytes)
        case nil: return false
        }
    }

    private static func isPublicV4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        switch (b[0], b[1], b[2]) {
        case (0, _, _), (10, _, _), (127, _, _): return false           // this network, private, loopback
        case (100, 64...127, _): return false                            // CGNAT 100.64/10
        case (169, 254, _): return false                                 // link-local
        case (172, 16...31, _): return false                             // private
        case (192, 0, 0), (192, 0, 2), (192, 88, 99), (192, 168, _): return false
        case (198, 18...19, _), (198, 51, 100), (203, 0, 113): return false // benchmark, documentation
        case (224...255, _, _): return false                             // multicast, reserved, broadcast
        default: return true
        }
    }

    private static func isPublicV6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        let embedded = Array(b[12..<16])
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return isPublicV4(embedded) } // ::ffff:a.b.c.d
        if b[0..<12].allSatisfy({ $0 == 0 }) { return false }            // ::, ::1, IPv4-compatible
        if b[0] == 0x00, b[1] == 0x64, b[2] == 0xff, b[3] == 0x9b, b[4..<12].allSatisfy({ $0 == 0 }) {
            return isPublicV4(embedded)                                  // NAT64 64:ff9b::/96
        }
        if b[0] == 0x20, b[1] == 0x02 { return isPublicV4(Array(b[2..<6])) } // 6to4
        if b[0] & 0xfe == 0xfc { return false }                          // ULA fc00::/7
        if b[0] == 0xfe, b[1] & 0x80 == 0x80 { return false }              // link-local fe80::/10, site-local fec0::/10
        if b[0] == 0xff { return false }                                 // multicast
        if b[0] == 0x20, b[1] == 0x01, b[2] == 0x0d, b[3] == 0xb8 { return false } // documentation
        if b[0] == 0x01, b[1..<8].allSatisfy({ $0 == 0 }) { return false } // discard 100::/64
        return true
    }

    /// getaddrinfo through the system resolver; numeric results only.
    static let systemResolve: Resolver = { host in
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(first) }
        var results: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if let address = entry.pointee.ai_addr,
               getnameinfo(address, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                results.append(String(cString: buffer))
            }
            cursor = entry.pointee.ai_next
        }
        return results
    }
}
