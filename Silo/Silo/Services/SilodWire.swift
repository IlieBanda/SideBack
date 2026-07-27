import Foundation

/// Hand-rolled encoder for the silod wire format.
///
/// The server serialises with `bincode::serialize`, whose layout is pinned
/// by tests in `silod/src/protocol.rs`:
/// - enum variant: `u32` little-endian, 0-based in declaration order
/// - `u32` / `u64`: fixed width, little-endian (no varints)
/// - `String` / `Vec<u8>`: `u64` length, then raw bytes
/// - `[u8; 32]`: 32 raw bytes, no length prefix
///
/// Keep `SilodRequest.variantIndex` in lockstep with the Rust `Request`
/// enum — the order there is the protocol.
enum SilodRequest {
    case hello(version: UInt32, token: Data)
    case createDirAll(path: String)
    case createFileWrite(path: String, truncate: Bool)
    case writeChunk(path: String, data: Data, hash: Data)
    case closeFile(path: String, hash: Data)
    case openFileRead(path: String)
    case readChunk(path: String, max: UInt32)
    case closeRead(path: String)
    case exists(path: String)
    case isDir(path: String)
    case remove(path: String)
    case rename(from: String, to: String)
    case copy(src: String, dst: String)
    case stat(path: String)
    case listDir(path: String)

    /// Must match the declaration order of `Request` in silod.
    private var variantIndex: UInt32 {
        switch self {
        case .hello: return 0
        case .createDirAll: return 1
        case .createFileWrite: return 2
        case .writeChunk: return 3
        case .closeFile: return 4
        case .openFileRead: return 5
        case .readChunk: return 6
        case .closeRead: return 7
        case .exists: return 8
        case .isDir: return 9
        case .remove: return 10
        case .rename: return 11
        case .copy: return 12
        case .stat: return 13
        case .listDir: return 14
        }
    }

    func encoded() -> Data {
        var out = Data()
        out.appendLE(variantIndex)

        switch self {
        case .hello(let version, let token):
            out.appendLE(version)
            out.appendBytes(token)
        case .createDirAll(let path),
             .openFileRead(let path),
             .closeRead(let path),
             .exists(let path),
             .isDir(let path),
             .remove(let path),
             .stat(let path),
             .listDir(let path):
            out.appendString(path)
        case .createFileWrite(let path, let truncate):
            out.appendString(path)
            out.append(truncate ? 1 : 0)
        case .writeChunk(let path, let data, let hash):
            out.appendString(path)
            out.appendBytes(data)
            out.appendFixed(hash, count: 32)
        case .closeFile(let path, let hash):
            out.appendString(path)
            out.appendFixed(hash, count: 32)
        case .readChunk(let path, let max):
            out.appendString(path)
            out.appendLE(max)
        case .rename(let from, let to):
            out.appendString(from)
            out.appendString(to)
        case .copy(let src, let dst):
            out.appendString(src)
            out.appendString(dst)
        }

        return out
    }
}

/// Mirrors `protocol::DirEntry` in silod.
struct SilodDirEntry {
    let name: String
    let isDir: Bool
    let size: UInt64
    /// Seconds since the Unix epoch, or nil when unavailable.
    let modified: Int64?
}

/// Mirrors the Rust `Response` enum. `listing`'s position (index 3, between
/// `stat` and `data`) matters — it shifts `data`/`eof`/`error` up by one from
/// what a naive reading of just this file would suggest; get it wrong and
/// every read/EOF/error response silently decodes as the wrong case.
enum SilodResponse {
    case ok
    case bool(Bool)
    case stat(exists: Bool, size: UInt64)
    case listing([SilodDirEntry])
    case data(Data)
    case eof
    case error(String)
}

enum SilodWireError: Error, LocalizedError {
    case truncated
    case unknownVariant(UInt32)

    var errorDescription: String? {
        switch self {
        case .truncated: return "server response cut short"
        case .unknownVariant(let index): return "unknown response type (\(index))"
        }
    }
}

extension SilodResponse {
    static func decode(_ payload: Data) throws -> SilodResponse {
        var cursor = Cursor(payload)
        let variant = try cursor.readLE(UInt32.self)

        switch variant {
        case 0: return .ok
        case 1: return .bool(try cursor.readByte() != 0)
        case 2:
            let exists = try cursor.readByte() != 0
            let size = try cursor.readLE(UInt64.self)
            return .stat(exists: exists, size: size)
        case 3:
            let count = Int(try cursor.readLE(UInt64.self))
            var entries: [SilodDirEntry] = []
            entries.reserveCapacity(count)
            for _ in 0..<count {
                let name = try cursor.readString()
                let isDir = try cursor.readByte() != 0
                let size = try cursor.readLE(UInt64.self)
                let hasModified = try cursor.readLE(UInt32.self) != 0
                let modified = hasModified ? try cursor.readLE(Int64.self) : nil
                entries.append(SilodDirEntry(name: name, isDir: isDir, size: size, modified: modified))
            }
            return .listing(entries)
        case 4: return .data(try cursor.readLengthPrefixedBytes())
        case 5: return .eof
        case 6: return .error(try cursor.readString())
        default: throw SilodWireError.unknownVariant(variant)
        }
    }
}

// MARK: - Byte plumbing

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendBytes(_ bytes: Data) {
        appendLE(UInt64(bytes.count))
        append(bytes)
    }

    mutating func appendString(_ string: String) {
        appendBytes(Data(string.utf8))
    }

    /// Fixed-size arrays carry no length prefix in bincode.
    mutating func appendFixed(_ bytes: Data, count: Int) {
        precondition(bytes.count == count, "expected \(count) bytes, got \(bytes.count)")
        append(bytes)
    }
}

private struct Cursor {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func readByte() throws -> UInt8 {
        guard offset < data.endIndex else { throw SilodWireError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readLE<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let width = MemoryLayout<T>.size
        guard offset + width <= data.endIndex else { throw SilodWireError.truncated }
        // Copy into a fresh buffer: the slice may not be word-aligned, and
        // loading unaligned via withUnsafeBytes is undefined behaviour.
        let bytes = [UInt8](data[offset..<(offset + width)])
        offset += width
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: T.self).littleEndian }
    }

    mutating func readLengthPrefixedBytes() throws -> Data {
        let length = Int(try readLE(UInt64.self))
        guard length >= 0, offset + length <= data.endIndex else { throw SilodWireError.truncated }
        defer { offset += length }
        return data[offset..<(offset + length)]
    }

    mutating func readString() throws -> String {
        String(decoding: try readLengthPrefixedBytes(), as: UTF8.self)
    }
}
