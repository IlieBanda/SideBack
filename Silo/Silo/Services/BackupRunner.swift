import Foundation

// MARK: - C trampolines
//
// idevice's `Mobilebackup2BackupDelegateFFI` fields are plain C function
// pointers, which can't capture state, so each one is a free function that
// pulls the real `BackupDelegateBridge` out of `context` via `Unmanaged`.

private func silo_free_disk_space(_ path: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) -> UInt64 {
    guard let context else { return 0 }
    return Unmanaged<BackupDelegateBridge>.fromOpaque(context).takeUnretainedValue().getFreeDiskSpace()
}

private func silo_open_file_read(
    _ path: UnsafePointer<CChar>?,
    _ outData: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ outLen: UnsafeMutablePointer<UInt>?,
    _ context: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    guard let context, let path, let outData, let outLen else {
        return BackupDelegateBridge.ffiError("invalid arguments to open_file_read")
    }
    let bridge = Unmanaged<BackupDelegateBridge>.fromOpaque(context).takeUnretainedValue()
    switch bridge.openFileRead(String(cString: path)) {
    case .success(let data):
        let count = data.count
        guard let buffer = malloc(max(count, 1)) else {
            return BackupDelegateBridge.ffiError("malloc failed in open_file_read")
        }
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress, count > 0 { memcpy(buffer, base, count) }
        }
        outData.pointee = buffer.bindMemory(to: UInt8.self, capacity: count)
        outLen.pointee = UInt(count)
        return nil
    case .failure(let error):
        return BackupDelegateBridge.ffiError("open_file_read: \(error)")
    }
}

private func silo_create_file_write(
    _ path: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    guard let context, let path else { return BackupDelegateBridge.ffiError("invalid arguments to create_file_write") }
    let bridge = Unmanaged<BackupDelegateBridge>.fromOpaque(context).takeUnretainedValue()
    if case .failure(let error) = bridge.createFileWrite(String(cString: path)) {
        return BackupDelegateBridge.ffiError("create_file_write: \(error)")
    }
    return nil
}

private func silo_write_chunk(
    _ path: UnsafePointer<CChar>?,
    _ data: UnsafePointer<UInt8>?,
    _ len: UInt,
    _ context: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    guard let context, let path else { return BackupDelegateBridge.ffiError("invalid arguments to write_chunk") }
    let bridge = Unmanaged<BackupDelegateBridge>.fromOpaque(context).takeUnretainedValue()
    let chunk: Data = (data != nil && len > 0) ? Data(bytes: data!, count: Int(len)) : Data()
    if case .failure(let error) = bridge.writeChunk(String(cString: path), chunk) {
        return BackupDelegateBridge.ffiError("write_chunk: \(error)")
    }
    return nil
}

private func silo_close_file(
    _ path: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    guard let context, let path else { return BackupDelegateBridge.ffiError("invalid arguments to close_file") }
    let bridge = Unmanaged<BackupDelegateBridge>.fromOpaque(context).takeUnretainedValue()
    if case .failure(let error) = bridge.closeFile(String(cString: path)) {
        return BackupDelegateBridge.ffiError("close_file: \(error)")
    }
    return nil
}

private func silo_create_dir_all(
    _ path: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    guard let context, let path else { return BackupDelegateBridge.ffiError("invalid arguments to create_dir_all") }
    let bridge = Unmanaged<BackupDelegateBridge>.fromOpaque(context).takeUnretainedValue()
    if case .failure(let error) = bridge.createDirAll(String(cString: path)) {
        return BackupDelegateBridge.ffiError("create_dir_all: \(error)")
    }
    return nil
}

private func silo_remove(
    _ path: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    guard let context, let path else { return BackupDelegateBridge.ffiError("invalid arguments to remove") }
    let bridge = Unmanaged<BackupDelegateBridge>.fromOpaque(context).takeUnretainedValue()
    if case .failure(let error) = bridge.remove(String(cString: path)) {
        return BackupDelegateBridge.ffiError("remove: \(error)")
    }
    return nil
}

private func silo_rename(
    _ from: UnsafePointer<CChar>?, _ to: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    guard let context, let from, let to else { return BackupDelegateBridge.ffiError("invalid arguments to rename") }
    let bridge = Unmanaged<BackupDelegateBridge>.fromOpaque(context).takeUnretainedValue()
    if case .failure(let error) = bridge.rename(String(cString: from), String(cString: to)) {
        return BackupDelegateBridge.ffiError("rename: \(error)")
    }
    return nil
}

private func silo_copy(
    _ src: UnsafePointer<CChar>?, _ dst: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    guard let context, let src, let dst else { return BackupDelegateBridge.ffiError("invalid arguments to copy") }
    let bridge = Unmanaged<BackupDelegateBridge>.fromOpaque(context).takeUnretainedValue()
    if case .failure(let error) = bridge.copy(String(cString: src), String(cString: dst)) {
        return BackupDelegateBridge.ffiError("copy: \(error)")
    }
    return nil
}

private func silo_exists(_ path: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) -> Bool {
    guard let context, let path else { return false }
    return Unmanaged<BackupDelegateBridge>.fromOpaque(context).takeUnretainedValue().exists(String(cString: path))
}

private func silo_is_dir(_ path: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) -> Bool {
    guard let context, let path else { return false }
    return Unmanaged<BackupDelegateBridge>.fromOpaque(context).takeUnretainedValue().isDir(String(cString: path))
}

/// Allocates the `CDirEntry` array and each `name` with `malloc`/`strdup`,
/// never Swift's own allocator — Rust frees both with `libc::free` on its
/// side, which is only valid for memory obtained that way (the default
/// allocator this vendored crate links against is the system libc allocator
/// on Darwin, same convention already used for `IdeviceFfiError`).
private func silo_list_dir(
    _ path: UnsafePointer<CChar>?,
    _ outEntries: UnsafeMutablePointer<UnsafeMutablePointer<CDirEntry>?>?,
    _ outCount: UnsafeMutablePointer<UInt>?,
    _ context: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    guard let context, let path, let outEntries, let outCount else {
        return BackupDelegateBridge.ffiError("invalid arguments to list_dir")
    }
    let bridge = Unmanaged<BackupDelegateBridge>.fromOpaque(context).takeUnretainedValue()
    switch bridge.listDir(String(cString: path)) {
    case .success(let entries):
        guard !entries.isEmpty else {
            outEntries.pointee = nil
            outCount.pointee = 0
            return nil
        }
        guard let buffer = malloc(entries.count * MemoryLayout<CDirEntry>.stride) else {
            return BackupDelegateBridge.ffiError("malloc failed in list_dir")
        }
        let typed = buffer.bindMemory(to: CDirEntry.self, capacity: entries.count)
        for (index, entry) in entries.enumerated() {
            typed[index] = CDirEntry(
                name: strdup(entry.name),
                is_dir: entry.isDir,
                is_file: !entry.isDir,
                size: entry.size,
                has_modified: entry.modified != nil,
                modified_unix_secs: entry.modified ?? 0
            )
        }
        outEntries.pointee = typed
        outCount.pointee = UInt(entries.count)
        return nil
    case .failure(let error):
        return BackupDelegateBridge.ffiError("list_dir: \(error)")
    }
}

private func silo_is_cancelled(_ context: UnsafeMutableRawPointer?) -> Bool {
    guard let context else { return false }
    return Unmanaged<BackupDelegateBridge>.fromOpaque(context).takeUnretainedValue().isCancelled
}

private func silo_on_progress(
    _ bytesDone: UInt64, _ bytesTotal: UInt64, _ overall: Double, _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    Unmanaged<BackupDelegateBridge>.fromOpaque(context).takeUnretainedValue()
        .progress(bytesDone: bytesDone, bytesTotal: bytesTotal, overall: overall)
}

/// Runs an actual `mobilebackup2_backup` against an already-open client,
/// streaming every file through a `BackupDelegateBridge` to `silod`.
///
/// Nothing in this codebase calls `BackupRunner.run` automatically — it
/// only runs when something explicitly hands it a live client handle. Real
/// device data moves only from that explicit call onward.
enum BackupRunner {
    enum Outcome {
        case completed
        case cancelled
        case failed(String)
    }

    /// Turns on (or changes) the on-device backup password before the real
    /// backup starts.
    ///
    /// This is a device *setting*, not a per-call option: once set, it
    /// persists and every future backup from any client — Silo, Finder, a
    /// stolen phone plugged into someone else's Mac — is encrypted with it
    /// until changed again. Without it, `BackupAgent2` silently omits
    /// Keychain, Health data, call history, and Safari history from the
    /// backup even though the run reports success, so a "complete" backup
    /// made without this is not actually complete.
    ///
    /// `oldPassword` must be the password *currently* set on the device, or
    /// nil if backup encryption has never been turned on. Passing the wrong
    /// old password fails rather than guessing.
    enum PasswordChangeResult {
        case success
        case failure(String)
    }

    static func changePassword(
        client: OpaquePointer,
        backupRoot: String,
        oldPassword: String?,
        newPassword: String,
        bridge: BackupDelegateBridge
    ) -> PasswordChangeResult {
        let context = Unmanaged.passUnretained(bridge).toOpaque()
        var delegate = makeDelegate(context: context)

        var response: UnsafeMutablePointer<IdeviceFfiError>?
        withUnsafePointer(to: &delegate) { delegatePtr in
            backupRoot.withCString { rootPtr in
                withOptionalCString(oldPassword) { oldPtr in
                    newPassword.withCString { newPtr in
                        response = mobilebackup2_change_password(client, rootPtr, oldPtr, newPtr, delegatePtr)
                    }
                }
            }
        }

        if let response {
            let message = response.pointee.message.map { String(cString: $0) } ?? "unknown error"
            idevice_error_free(response)
            return .failure(message)
        }
        return .success
    }

    private static func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
        guard let string else { return body(nil) }
        return string.withCString(body)
    }

    private static func makeDelegate(context: UnsafeMutableRawPointer) -> Mobilebackup2BackupDelegateFFI {
        Mobilebackup2BackupDelegateFFI(
            context: context,
            get_free_disk_space: silo_free_disk_space,
            open_file_read: silo_open_file_read,
            create_file_write: silo_create_file_write,
            write_chunk: silo_write_chunk,
            close_file: silo_close_file,
            create_dir_all: silo_create_dir_all,
            remove: silo_remove,
            rename: silo_rename,
            copy: silo_copy,
            exists: silo_exists,
            is_dir: silo_is_dir,
            list_dir: silo_list_dir,
            is_cancelled: silo_is_cancelled,
            on_progress: silo_on_progress
        )
    }

    /// Blocks the calling thread for the whole backup — call this off the
    /// main thread (see the `DispatchQueue.global` pattern in DeviceTunnel's
    /// callers).
    static func run(
        client: OpaquePointer,
        backupRoot: String,
        deviceUUID: String,
        bridge: BackupDelegateBridge
    ) -> Outcome {
        let context = Unmanaged.passUnretained(bridge).toOpaque()
        var delegate = makeDelegate(context: context)

        var response: UnsafeMutablePointer<IdeviceFfiError>?
        withUnsafePointer(to: &delegate) { delegatePtr in
            backupRoot.withCString { rootPtr in
                deviceUUID.withCString { uuidPtr in
                    response = mobilebackup2_backup(client, rootPtr, uuidPtr, nil, delegatePtr, nil)
                }
            }
        }

        if let response {
            let message = response.pointee.message.map { String(cString: $0) } ?? "unknown error"
            idevice_error_free(response)
            return bridge.isCancelled ? .cancelled : .failed(message)
        }

        if let failure = bridge.firstFailure {
            return .failed(failure)
        }
        return bridge.isCancelled ? .cancelled : .completed
    }
}
