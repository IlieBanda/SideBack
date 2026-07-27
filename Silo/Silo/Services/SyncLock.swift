import Foundation

/// Announces an iTunes-style sync to the device for the duration of a
/// backup, via the same notification sequence the reference
/// `idevicebackup2` uses.
///
/// This used to also open `/com.apple.itunes.lock_sync` over AFC and take a
/// real `flock` on it. That crashed on the very first call: the lock
/// operation crossed the FFI boundary as a `#[repr(u64)] enum`, which
/// cbindgen renders as a C enum, which Swift imports with a 32-bit raw
/// value — so the upper half of the 64-bit argument Rust expected was
/// garbage, and matching it as a `u64` discriminant was undefined
/// behaviour. Fixing the ABI (a plain `UInt64` instead of an enum) stopped
/// the crash, but by then a second data point had shown up: ByeTunes
/// (github.com/EduAlexxis/ByeTunes), an independent shipped app built on
/// the same `idevice` crate, posts exactly these four notifications before
/// touching the device's media library and never takes the AFC lock at
/// all. Two different codebases converging on "notifications only" is a
/// better signal than one unverified guess at what `idevicebackup2` does
/// internally, so the lock attempt is gone rather than re-added correctly.
///
/// Measured motivation, for whoever revisits this: a real run moved 931
/// files in 101 seconds of actual transfer spread across 17 minutes wall
/// clock — 88% idle, in stalls of 183, 208 and 502 seconds. Whether
/// announcing the sync actually shortens those stalls is what this class
/// is here to test; nothing about it is guaranteed yet.
final class SyncLock {
    /// Off by default. An unverified behavioural experiment on top of a
    /// backup path that already works without it — opt in rather than
    /// forced on every run.
    private static let enabledKey = "silo.syncLock.enabled"
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private static let willStart = "com.apple.itunes-mobdev.syncWillStart"
    private static let lockRequest = "com.apple.itunes-mobdev.syncLockRequest"
    private static let didStart = "com.apple.itunes-mobdev.syncDidStart"
    private static let didFinish = "com.apple.itunes-mobdev.syncDidFinish"

    private let lock = NSLock()
    private var notificationProxy: OpaquePointer?

    private(set) var isHeld = false
    private(set) var failureReason: String?

    func acquire(adapter: OpaquePointer, handshake: OpaquePointer) {
        DebugLog.note("SyncLock: connecting to notification_proxy")
        var np: OpaquePointer?
        if let error = notification_proxy_connect_rsd(adapter, handshake, &np) {
            failureReason = "notification_proxy: \(DeviceTunnel.errorMessage(error))"
            idevice_error_free(error)
            return
        }
        notificationProxy = np
        DebugLog.note("SyncLock: notification_proxy ready, sending sync notifications")
        post(Self.willStart)
        post(Self.lockRequest)
        post(Self.didStart)
        isHeld = true
        failureReason = nil
        DebugLog.note("SyncLock: notifications sent")
    }

    /// Safe to call more than once, and safe to call when `acquire` never
    /// ran or failed.
    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard let notificationProxy else { return }
        if isHeld {
            DebugLog.note("SyncLock: releasing")
            post(Self.didFinish)
        }
        notification_proxy_client_free(notificationProxy)
        self.notificationProxy = nil
        isHeld = false
    }

    private func post(_ name: String) {
        guard let notificationProxy else { return }
        if let error = name.withCString({ notification_proxy_post(notificationProxy, $0) }) {
            idevice_error_free(error)
        }
    }

    deinit { release() }
}
