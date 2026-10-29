import Foundation

/// Chrome-compatible UTF-8 CSV. Quoted newlines, escaped quotes, BOM and CRLF are supported.
/// Unknown columns are ignored; notes are reported because the destination cannot represent them.
public enum BrowserPasswordCSV {
    public static func read(_ data: Data) throws -> ChromiumPasswordReadResult {
        guard data.count <= 32 * 1024 * 1024, var text = String(data: data, encoding: .utf8) else {
            throw BrowserAuthenticationImportError.invalidCSV
        }
        if text.first == "\u{feff}" { text.removeFirst() }
        let bytes = Array(text.utf8)
        var rows: [[String]] = [], row: [String] = [], field: [UInt8] = []
        var quoted = false, closed = false, index = 0
        func finishField() throws {
            guard let value = String(bytes: field, encoding: .utf8) else { throw BrowserAuthenticationImportError.invalidCSV }
            row.append(value); field = []; closed = false
        }
        while index < bytes.count {
            let byte = bytes[index]
            if quoted {
                if byte == 34 {
                    if index + 1 < bytes.count, bytes[index + 1] == 34 { field.append(34); index += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(byte) }
            } else if byte == 34 {
                guard field.isEmpty, !closed else { throw BrowserAuthenticationImportError.invalidCSV }
                quoted = true
            } else if byte == 44 { try finishField() }
            else if byte == 10 || byte == 13 {
                if byte == 13, index + 1 < bytes.count, bytes[index + 1] == 10 { index += 1 }
                try finishField(); rows.append(row); row = []
            } else {
                guard !closed else { throw BrowserAuthenticationImportError.invalidCSV }
                field.append(byte)
            }
            guard rows.count <= 100_000, row.count <= 64, field.count <= 1_048_576 else { throw BrowserAuthenticationImportError.invalidCSV }
            index += 1
        }
        guard !quoted else { throw BrowserAuthenticationImportError.invalidCSV }
        if !field.isEmpty || !row.isEmpty || closed { try finishField(); rows.append(row) }
        let header = rows.first?.map { $0.lowercased() } ?? []
        guard !header.isEmpty, Set(header).count == header.count,
              let urlIndex = header.firstIndex(of: "url"), let usernameIndex = header.firstIndex(of: "username"),
              let passwordIndex = header.firstIndex(of: "password") else { throw BrowserAuthenticationImportError.invalidCSV }
        var result = ChromiumPasswordReadResult()
        for row in rows.dropFirst() {
            if row == [""] { continue }
            guard row.count == header.count else { throw BrowserAuthenticationImportError.invalidCSV }
            if let note = header.firstIndex(of: "note") ?? header.firstIndex(of: "notes"), !row[note].isEmpty { result.unrepresentedNotes += 1 }
            if let otp = header.firstIndex(of: "otpauth"), !row[otp].isEmpty { result.unrepresentedOTP += 1 }
            if let passkey = header.firstIndex(of: "passkey"), !row[passkey].isEmpty { result.unrepresentedPasskeys += 1 }
            if row[passwordIndex].isEmpty { result.unsupported += 1; continue }
            let origin = row[urlIndex]
            guard ChromiumPasswordReader.validWebURL(origin), var components = URLComponents(string: origin) else {
                result.unsupported += 1; continue
            }
            components.path = "/"; components.query = nil; components.fragment = nil
            guard let realm = components.string else { throw BrowserAuthenticationImportError.invalidCSV }
            result.passwords.append(.init(realm: realm, origin: origin, action: "", usernameElement: "", username: row[usernameIndex],
                passwordElement: "", password: row[passwordIndex], created: 0, lastUsed: 0, modified: 0, blocked: false, scheme: 0))
        }
        return result
    }
}
