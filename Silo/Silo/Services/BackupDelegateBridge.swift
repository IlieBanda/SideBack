import CryptoKit
import Foundation

/// Bridges mobilebackup2's delegate callbacks to a `SilodClient`.
///
/// The callbacks that call into this class run synchronously, on whatever
/// thread `BackupRunner.run` was called from — never the main thread.
/// `SilodClient` is an async actor, so each callback blocks that thread on
/// a semaphore while a `Task` awaits the actor call. That's only safe
/// because the calling thread is dedicated to the backup and has nothing
/// else scheduled on it.
final class BackupDelegateBridge {
    private let client: SilodClient
    private let remoteRoot: String
    private let onProgress: (UInt64, UInt64, Double) -> Void

    private let stateLock = NSLock()
    private var cancelRequested = false
    private(set) var firstFailure: String?

    /// Last few delegate calls that actually reached this bridge, in order.
    /// mobilebackup2's connection can die before ever calling any of them
    /// (during its own protocol handshake) or partway through — this is
    /// what tells the two apart when a run fails.
    private var activityTrail: [String] = []
    private static let activityTrailLimit = 12

    var recentActivity: [String] {
        stateLock.lock(); defer { stateLock.unlock() }
        return activityTrail
    }

    /// When the underlying tunnel wedges (observed: a dropped packet in
    /// LocalDevVPN/StosVPN's reliable-delivery layer stalls its receive
    /// buffer forever, since nothing above it ever asks for a
    /// retransmission), the blocking read for the next DeviceLink message
    /// never returns and none of these delegate calls fire again. This is
    /// the only "are we still actually moving" signal available from the
    /// Swift side while that read is blocked deep in the Rust FFI call.
    private var lastActivityAt = Date()

    /// One-shot phase markers so the log answers "where did the time
    /// actually go" after the fact — directory/manifest setup, real file
    /// transfer, and the final housekeeping calls (rename/remove/copy after
    /// the last write) are easy to conflate into one blob otherwise.
    private var loggedFirstDirCreate = false
    private var loggedFirstWrite = false
    private var loggedFirstPostWriteHousekeeping = false

    var secondsSinceLastActivity: TimeInterval {
        stateLock.lock(); defer { stateLock.unlock() }
        return Date().timeIntervalSince(lastActivityAt)
    }

    private func logActivity(_ entry: String) {
        stateLock.lock()
        activityTrail.append(entry)
        if activityTrail.count > Self.activityTrailLimit { activityTrail.removeFirst() }
        lastActivityAt = Date()
        stateLock.unlock()
    }

    /// Running SHA-256 per path currently being written. silod verifies the
    /// whole file's hash on CloseFile, so this has to span every WriteChunk
    /// call for that path, not just the most recent chunk.
    private var writeHashers: [String: SHA256] = [:]

    /// Total bytes actually handed to silod over this whole run.
    ///
    /// mobilebackup2's own `bytes_done`/`bytes_total` are per upload batch —
    /// both reset every `DLMessageUploadFiles` — so neither says anything
    /// about how much of the backup has moved. Counting writes here is the
    /// only number that means "this much is on the server".
    private var totalBytesWritten: UInt64 = 0

    var bytesWritten: UInt64 {
        stateLock.lock(); defer { stateLock.unlock() }
        return totalBytesWritten
    }

    init(client: SilodClient, remoteRoot: String, onProgress: @escaping (UInt64, UInt64, Double) -> Void) {
        self.client = client
        self.remoteRoot = remoteRoot
        self.onProgress = onProgress
    }

    func requestCancel() {
        stateLock.lock(); cancelRequested = true; stateLock.unlock()
    }

    var isCancelled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return cancelRequested
    }

    func recordFailure(_ message: String) {
        stateLock.lock()
        if firstFailure == nil { firstFailure = message }
        stateLock.unlock()
    }

    private func remotePath(for devicePath: String) -> String {
        let trimmed = devicePath.hasPrefix("/") ? String(devicePath.dropFirst()) : devicePath
        return trimmed.isEmpty ? remoteRoot : "\(remoteRoot)/\(trimmed)"
    }

    private func blocking<T>(_ operation: @escaping () async throws -> T) -> Swift.Result<T, Error> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task {
            do { box.value = .success(try await operation()) }
            catch { box.value = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return box.value ?? .failure(SilodError.transport("bridge did not return a result"))
    }

    // MARK: - BackupDelegate operations

    func getFreeDiskSpace() -> UInt64 {
        // silod has no free-space query yet — report a large number rather
        // than fabricate one that looks precise but isn't.
        .max / 2
    }

    func openFileRead(_ path: String) -> Swift.Result<Data, Error> {
        logActivity("openFileRead \(path)")
        if isCancelled { return .failure(CancellationError()) }
        let remote = remotePath(for: path)
        let result: Swift.Result<Data, Error> = blocking { [client] in
            if case .error(let message) = try await client.call(.openFileRead(path: remote)) {
                throw SilodError.server(message)
            }
            var buffer = Data()
            while true {
                switch try await client.call(.readChunk(path: remote, max: 1_048_576)) {
                case .data(let chunk):
                    buffer.append(chunk)
                case .eof:
                    _ = try? await client.call(.closeRead(path: remote))
                    return buffer
                case .error(let message):
                    throw SilodError.server(message)
                default:
                    throw SilodError.server("unexpected response to readChunk")
                }
            }
        }
        if case .failure(let error) = result { recordFailure("openFileRead: \(error)") }
        return result
    }

    func createFileWrite(_ path: String) -> Swift.Result<Void, Error> {
        logActivity("createFileWrite \(path)")
        if isCancelled { return .failure(CancellationError()) }
        let remote = remotePath(for: path)
        stateLock.lock(); writeHashers[remote] = SHA256(); stateLock.unlock()
        let result: Swift.Result<Void, Error> = blocking { [client] in
            try await Self.expectOk(client.call(.createFileWrite(path: remote, truncate: true)))
        }
        if case .failure(let error) = result { recordFailure("createFileWrite: \(error)") }
        return result
    }

    func writeChunk(_ path: String, _ data: Data) -> Swift.Result<Void, Error> {
        logActivity("writeChunk \(path) (\(data.count)B)")
        stateLock.lock()
        let isFirst = !loggedFirstWrite
        loggedFirstWrite = true
        stateLock.unlock()
        if isFirst { DebugLog.note("Phase: file content transfer started") }
        if isCancelled { return .failure(CancellationError()) }
        let remote = remotePath(for: path)
        stateLock.lock()
        writeHashers[remote, default: SHA256()].update(data: data)
        stateLock.unlock()
        let chunkHash = Data(SHA256.hash(data: data))
        let result: Swift.Result<Void, Error> = blocking { [client] in
            try await Self.expectOk(client.call(.writeChunk(path: remote, data: data, hash: chunkHash)))
        }
        if case .failure(let error) = result {
            recordFailure("writeChunk: \(error)")
        } else {
            stateLock.lock(); totalBytesWritten += UInt64(data.count); stateLock.unlock()
        }
        return result
    }

    func closeFile(_ path: String) -> Swift.Result<Void, Error> {
        logActivity("closeFile \(path)")
        let remote = remotePath(for: path)
        stateLock.lock()
        let hasher = writeHashers.removeValue(forKey: remote)
        stateLock.unlock()
        guard let hasher else {
            let error = SilodError.transport("closeFile without a preceding createFileWrite: \(remote)")
            recordFailure("closeFile: \(error)")
            return .failure(error)
        }
        let digest = Data(hasher.finalize())
        let result: Swift.Result<Void, Error> = blocking { [client] in
            try await Self.expectOk(client.call(.closeFile(path: remote, hash: digest)))
        }
        if case .failure(let error) = result { recordFailure("closeFile: \(error)") }
        return result
    }

    func createDirAll(_ path: String) -> Swift.Result<Void, Error> {
        logActivity("createDirAll \(path)")
        stateLock.lock()
        let isFirst = !loggedFirstDirCreate
        loggedFirstDirCreate = true
        stateLock.unlock()
        if isFirst { DebugLog.note("Phase: directory structure creation started") }
        let remote = remotePath(for: path)
        let result: Swift.Result<Void, Error> = blocking { [client] in
            try await Self.expectOk(client.call(.createDirAll(path: remote)))
        }
        if case .failure(let error) = result { recordFailure("createDirAll: \(error)") }
        return result
    }

    /// Fires once, the first time `rename`/`remove`/`copy` runs after at
    /// least one real write — an approximation of "finalization started"
    /// (Manifest.db/Status.plist juggling), since there's no message from
    /// the device that says "this is the last file" ahead of time.
    private func noteHousekeepingIfNeeded() {
        stateLock.lock()
        let shouldLog = loggedFirstWrite && !loggedFirstPostWriteHousekeeping
        loggedFirstPostWriteHousekeeping = loggedFirstPostWriteHousekeeping || loggedFirstWrite
        stateLock.unlock()
        if shouldLog { DebugLog.note("Phase: looks like finalization (rename/remove/copy after the first write)") }
    }

    func remove(_ path: String) -> Swift.Result<Void, Error> {
        logActivity("remove \(path)")
        noteHousekeepingIfNeeded()
        let remote = remotePath(for: path)
        let result: Swift.Result<Void, Error> = blocking { [client] in
            try await Self.expectOk(client.call(.remove(path: remote)))
        }
        if case .failure(let error) = result { recordFailure("remove: \(error)") }
        return result
    }

    func rename(_ from: String, _ to: String) -> Swift.Result<Void, Error> {
        logActivity("rename \(from) -> \(to)")
        noteHousekeepingIfNeeded()
        let remoteFrom = remotePath(for: from)
        let remoteTo = remotePath(for: to)
        let result: Swift.Result<Void, Error> = blocking { [client] in
            try await Self.expectOk(client.call(.rename(from: remoteFrom, to: remoteTo)))
        }
        if case .failure(let error) = result { recordFailure("rename: \(error)") }
        return result
    }

    func copy(_ src: String, _ dst: String) -> Swift.Result<Void, Error> {
        logActivity("copy \(src) -> \(dst)")
        noteHousekeepingIfNeeded()
        let remoteSrc = remotePath(for: src)
        let remoteDst = remotePath(for: dst)
        let result: Swift.Result<Void, Error> = blocking { [client] in
            try await Self.expectOk(client.call(.copy(src: remoteSrc, dst: remoteDst)))
        }
        if case .failure(let error) = result { recordFailure("copy: \(error)") }
        return result
    }

    func exists(_ path: String) -> Bool {
        let remote = remotePath(for: path)
        let result: Swift.Result<Bool, Error> = blocking { [client] in
            switch try await client.call(.exists(path: remote)) {
            case .bool(let value): return value
            case .error(let message): throw SilodError.server(message)
            default: throw SilodError.server("unexpected response to exists")
            }
        }
        if case .failure(let error) = result { recordFailure("exists: \(error)") }
        return (try? result.get()) ?? false
    }

    /// Answers the device's `DLContentsOfDirectory` query against what
    /// `silod` actually has, not the phone's own local filesystem — this is
    /// what lets a device that already has a completed backup on the server
    /// recognize files it doesn't need to resend after an interruption,
    /// instead of restarting the whole backup from zero every time.
    func listDir(_ path: String) -> Swift.Result<[SilodDirEntry], Error> {
        logActivity("listDir \(path)")
        let remote = remotePath(for: path)
        let result: Swift.Result<[SilodDirEntry], Error> = blocking { [client] in
            switch try await client.call(.listDir(path: remote)) {
            case .listing(let entries): return entries
            case .error(let message): throw SilodError.server(message)
            default: throw SilodError.server("unexpected response to listDir")
            }
        }
        if case .failure(let error) = result { recordFailure("listDir: \(error)") }
        return result
    }

    func isDir(_ path: String) -> Bool {
        let remote = remotePath(for: path)
        let result: Swift.Result<Bool, Error> = blocking { [client] in
            switch try await client.call(.isDir(path: remote)) {
            case .bool(let value): return value
            case .error(let message): throw SilodError.server(message)
            default: throw SilodError.server("unexpected response to isDir")
            }
        }
        if case .failure(let error) = result { recordFailure("isDir: \(error)") }
        return (try? result.get()) ?? false
    }

    func progress(bytesDone: UInt64, bytesTotal: UInt64, overall: Double) {
        onProgress(bytesWritten, bytesTotal, overall)
    }

    private static func expectOk(_ response: SilodResponse) async throws {
        switch response {
        case .ok: return
        case .error(let message): throw SilodError.server(message)
        default: throw SilodError.server("expected Ok, got something else")
        }
    }

    // MARK: - C-compatible error allocation
    //
    // Rust frees these via `idevice_error_free`, which does
    // `CString::from_raw` then `Box::from_raw` — i.e. plain libc free().
    // This vendored crate uses Rust's default allocator, which on Darwin
    // *is* libc malloc/free, so building the struct with malloc/strdup
    // (not Swift's own allocator) is required for that free to be valid.
    static func ffiError(_ message: String) -> UnsafeMutablePointer<IdeviceFfiError>? {
        guard let raw = malloc(MemoryLayout<IdeviceFfiError>.stride) else { return nil }
        let ptr = raw.bindMemory(to: IdeviceFfiError.self, capacity: 1)
        ptr.pointee = IdeviceFfiError(code: -1, sub_code: 0, message: UnsafePointer(strdup(message)))
        return ptr
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: Swift.Result<T, Error>?
}
