import Darwin
import Foundation
import zlib

/// A bounded ZIP reader for stored/deflated, single-volume exports. Central and local names,
/// sizes, flags, CRCs and extents must agree. ZIP64, encryption, links and special files fail closed.
/// Entry names never become extraction paths. Unknown payloads are streamed and discarded.
enum SafariExportArchive {
    static let maximumBytes = 256 * 1024 * 1024
    static let maximumEntryBytes = 64 * 1024 * 1024
    private static func number(_ data: Data, _ offset: Int, _ width: Int) -> Int {
        (0..<width).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
    }
    static func read(_ file: URL, entry: (String, @escaping () throws -> Data) throws -> Void) throws {
        let folder = try OrbitSecureDirectory.open(file.deletingLastPathComponent(), create: false)
        let fd = try folder.openFile(file.lastPathComponent)
        defer { Darwin.close(fd) }
        let size = Int(folder.size(file.lastPathComponent))
        func read(_ offset: Int, _ count: Int) throws -> Data {
            guard offset >= 0, count >= 0, offset <= size, count <= size - offset else { throw ArcImportError.unreadableSourceDocument }
            var bytes = Data(count: count)
            let amount = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
            guard amount == count else { throw ArcImportError.unreadableSourceDocument }; return bytes
        }
        guard size >= 22, size <= maximumBytes else { throw ArcImportError.unsupportedSourceFile }
        let tail = try read(max(0, size - 65_557), min(size, 65_557))
        guard let end = (0...(tail.count - 22)).reversed().first(where: {
            number(tail, $0, 4) == 101010256 && $0 + 22 + number(tail, $0 + 20, 2) == tail.count
        }) else { throw ArcImportError.unreadableSourceDocument }
        let entries = number(tail, end + 10, 2), centralSize = number(tail, end + 12, 4), centralStart = number(tail, end + 16, 4)
        guard number(tail, end + 4, 2) == 0, number(tail, end + 6, 2) == 0,
              entries > 0, entries <= 128, number(tail, end + 8, 2) == entries,
              centralStart + centralSize == size - tail.count + end else { throw ArcImportError.unsupportedSourceFile }
        var offset = centralStart, extent = 0, total = 0, names = Set<String>()
        for _ in 0..<entries {
            let header = try read(offset, 46)
            guard number(header, 0, 4) == 33639248 else { throw ArcImportError.unreadableSourceDocument }
            let flags = number(header, 8, 2), method = number(header, 10, 2), crc = number(header, 16, 4)
            let compressed = number(header, 20, 4), expanded = number(header, 24, 4), nameSize = number(header, 28, 2)
            let localOffset = number(header, 42, 4), mode = number(header, 38, 4) >> 16
            let rawName = try read(offset + 46, nameSize)
            guard let name = String(data: rawName, encoding: .utf8), !name.isEmpty, name.utf8.count <= 1024,
                  !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  number(header, 34, 2) == 0, flags & ~0x080e == 0, [0, 8].contains(method),
                  expanded <= maximumEntryBytes, compressed <= maximumBytes else { throw ArcImportError.unsupportedSourceFile }
            let directory = name.hasSuffix("/")
            let path = directory ? String(name.dropLast()) : name
            guard path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ OrbitSecureDirectory.validName($0) }),
                  mode & 0xf000 == 0 || mode & 0xf000 == (directory ? 0x4000 : 0x8000),
                  !directory || expanded == 0 else { throw ArcImportError.unsupportedSourceFile }
            let local = try read(localOffset, 30)
            guard localOffset >= extent, number(local, 0, 4) == 67324752,
                  number(local, 6, 2) == flags, number(local, 8, 2) == method,
                  number(local, 26, 2) == nameSize, try read(localOffset + 30, nameSize) == rawName else { throw ArcImportError.unreadableSourceDocument }
            if flags & 8 == 0 {
                guard number(local, 14, 4) == crc, number(local, 18, 4) == compressed, number(local, 22, 4) == expanded else { throw ArcImportError.unreadableSourceDocument }
            }
            let start = localOffset + 30 + nameSize + number(local, 28, 2)
            extent = start + compressed
            guard extent <= centralStart else { throw ArcImportError.unreadableSourceDocument }
            total += expanded; guard total <= maximumBytes else { throw ArcImportError.unsupportedSourceFile }
            if flags & 8 != 0 {
                let first = try read(extent, 4)
                let descriptorOffset = extent + (number(first, 0, 4) == 134695760 ? 4 : 0)
                let descriptor = try read(descriptorOffset, 12)
                guard number(descriptor, 0, 4) == crc, number(descriptor, 4, 4) == compressed,
                      number(descriptor, 8, 4) == expanded else { throw ArcImportError.unreadableSourceDocument }
                extent = descriptorOffset + 12
                guard extent <= centralStart else { throw ArcImportError.unreadableSourceDocument }
            }
            var stream = z_stream(), input = Data(), consumed = 0, outputSize = 0, checksum: uLong = 0, finished = false
            if method == 8 {
                guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw ArcImportError.unreadableSourceDocument }
            }
            defer { if method == 8 { inflateEnd(&stream) } }
            func next() throws -> Data {
                if finished { return Data() }
                while true {
                var output: Data
                if method == 0 {
                    output = try read(start + consumed, min(64 * 1024, compressed - consumed)); consumed += output.count
                    finished = consumed == compressed
                } else {
                    if input.isEmpty && consumed < compressed {
                        input = try read(start + consumed, min(64 * 1024, compressed - consumed)); consumed += input.count
                    }
                    output = Data(count: 64 * 1024)
                    var used = 0, produced = 0
                    let status = input.withUnsafeBytes { source in
                        output.withUnsafeMutableBytes { target in
                            stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                            stream.avail_in = uInt(input.count)
                            stream.next_out = target.bindMemory(to: Bytef.self).baseAddress
                            stream.avail_out = uInt(target.count)
                            let status = inflate(&stream, Z_NO_FLUSH)
                            used = input.count - Int(stream.avail_in); produced = target.count - Int(stream.avail_out)
                            return status
                        }
                    }
                    input = Data(input.dropFirst(used)); output.count = produced
                    guard status == Z_OK || status == Z_STREAM_END, used > 0 || produced > 0 else { throw ArcImportError.unreadableSourceDocument }
                    finished = status == Z_STREAM_END
                    if finished { guard input.isEmpty, consumed == compressed else { throw ArcImportError.unreadableSourceDocument } }
                }
                outputSize += output.count
                guard outputSize <= expanded else { throw ArcImportError.unsupportedSourceFile }
                checksum = output.withUnsafeBytes { crc32(checksum, $0.bindMemory(to: Bytef.self).baseAddress, uInt(output.count)) }
                if finished { guard outputSize == expanded, checksum == crc else { throw ArcImportError.unreadableSourceDocument } }
                if !output.isEmpty || finished { return output }
                }
            }
            if !directory { try entry(name, next) }
            while !(try next()).isEmpty { }
            offset += 46 + nameSize + number(header, 30, 2) + number(header, 32, 2)
        }
        guard offset == centralStart + centralSize else { throw ArcImportError.unreadableSourceDocument }
    }
}
