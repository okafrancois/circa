import BrowserCore
import Foundation

// A non-GUI, path-free gate: validate exactly the bytes the publisher will back up and copy.
// Never echo the document, decoded destinations or decoder errors to logs.
do {
    let limit = BrowserSessionDocument.defaultMaximumInputBytes
    var data = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: min(64 * 1024, limit + 1 - data.count)), !chunk.isEmpty {
        data.append(chunk)
        guard data.count <= limit else { exit(65) }
    }
    let document = try BrowserSessionDocument.decode(data)
    guard !document.profiles.isEmpty, !document.spaces.isEmpty else { exit(65) }
    exit(0)
} catch {
    FileHandle.standardError.write(Data("Live session graph validation failed\n".utf8))
    exit(65)
}
