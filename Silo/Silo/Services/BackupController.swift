import CryptoKit
import Foundation
import UIKit

/// Orchestrates one backup run: opens the device tunnel, connects to
/// silod, streams the backup through `BackupDelegateBridge`, and exposes
/// live progress plus a cancel button to SwiftUI.
///
/// No automatic retry here on purpose: a failed attempt can be the device's
/// own "enter your passcode to trust this backup" system dialog being
/// answered too slowly (or the dialog answering something else entirely) —
/// silently re-firing a fresh attempt on a fixed timer just races that
/// dialog again. The user retries manually, on their own schedule.
@MainActor
final class BackupController: ObservableObject {
    enum Phase {
        case idle
        case connecting
        /// `bytesSent` is cumulative across the whole run; `batchTotal` is
        /// only the size of the upload batch in flight, and `overall` is the
        /// device's own estimate of how far the backup as a whole has got.
        /// Three different scales — never present them as one figure.
        case running(bytesSent: UInt64, batchTotal: UInt64, overall: Double)
        case cancelling
        case completed
        case cancelled(activity: [String], debugLog: String, abandoned: Bool)
        case failed(String, activity: [String], debugLog: String)
    }

    /// How long we wait for `mobilebackup2` to actually notice the cancel
    /// flag before we stop waiting on it. The flag is only read inside the
    /// delegate callbacks, so a run blocked before its first callback (the
    /// device still spinning up BackupAgent2, or sitting on its passcode
    /// dialog) never observes it — without this the UI sits in
    /// `.cancelling` forever.
    private static let cancelGraceSeconds: UInt64 = 6

    /// If nothing has reached `BackupDelegateBridge` for this long while a
    /// run is active, the run is treated as wedged rather than merely slow.
    ///
    /// Root cause found and patched at the transport layer: `idevice`'s
    /// vendored `jktcp` (the userspace TCP stack it runs over the
    /// CoreDeviceProxy tunnel) always advertised a ~16.7 MB receive window
    /// and dropped out-of-order data with zero ACK feedback — no SACK. One
    /// lost packet meant discarding everything the device had already sent
    /// above it (megabytes, observed as hundreds of dropped segments within
    /// 2ms) with no signal to the device to retransmit early, so recovery
    /// depended entirely on the device's own blind RTO. See
    /// vendor/jktcp-patched/src/adapter.rs for the fix: a bounded ~256KB
    /// window plus a re-ACK on out-of-order arrival so the device can fast-
    /// retransmit. With that fixed, a stall this long is no longer explained
    /// by the known cause — treat it as genuinely wedged rather than wait
    /// out a recovery that isn't coming.
    private static let stallTimeoutSeconds: TimeInterval = 90

    @Published private(set) var phase: Phase = .idle

    /// Opt-in: hold the process open with background location updates so a
    /// backup survives the screen turning off. Off by default — it costs
    /// battery and puts a location indicator in the status bar, so it is
    /// the user's call, not a default.
    @Published var keepAliveInBackground = false

    /// Whether the device granted the iTunes sync lock for this run. Without
    /// it the device interleaves its own sync work and the transfer crawls,
    /// so it is worth surfacing rather than silently degrading.
    @Published private(set) var syncLockStatus: String?

    /// Set only in the edge case where the device already had a backup
    /// password Silo doesn't manage — see the `WillEncrypt` handling in
    /// `runBackup`.
    @Published private(set) var encryptionStatus: String?

    private var bridge: BackupDelegateBridge?
    private var silodClient: SilodClient?
    private var logOffset: UInt64 = 0
    /// Bumped on every start so a stale cancel watchdog from an earlier
    /// attempt can't land on a newer one.
    private var runToken = 0
    private var isFinished = false
    private var stallWatchdogTask: Task<Void, Never>?

    var isRunning: Bool {
        switch phase {
        case .connecting, .running, .cancelling: return true
        case .idle, .completed, .cancelled, .failed: return false
        }
    }

    /// The protocol log for the attempt in flight, so a slow run can be
    /// inspected where it actually is without having to cancel it first or
    /// wait for a failure that may never come.
    var liveDebugLog: String {
        DebugLog.tail(from: logOffset)
    }

    /// The same log trimmed to something a single SwiftUI `Text` can lay out
    /// without stalling the main thread. Rendering the full tail of a
    /// running backup froze the UI outright — the file is the archive, the
    /// screen only needs the last screenful.
    var liveDebugTail: String {
        DebugLog.tail(from: logOffset, maxBytes: 16_000)
    }

    /// Starts a real `mobilebackup2` backup. Callers are responsible for
    /// having already gotten the user's explicit confirmation — this call
    /// itself has no further gate.
    func start(gatewayAddress: String, pairingFileData: Data, destination: BackupDestination, token: String) {
        guard !isRunning else { return }
        runToken &+= 1
        isFinished = false
        logOffset = DebugLog.currentOffset()
        phase = .connecting
        syncLockStatus = nil
        encryptionStatus = nil
        // The whole transfer lives in this process: if the screen locks,
        // iOS suspends us and the tunnel dies mid-backup (seen in the logs
        // as the keep-alives simply stopping).
        UIApplication.shared.isIdleTimerDisabled = true
        // Only does anything if the user turned it on and granted "Always";
        // otherwise the backup simply needs the screen to stay awake.
        if keepAliveInBackground { BackgroundKeepAlive.shared.start() }

        Task {
            do {
                let client = try await SilodClient.connect(
                    host: destination.host,
                    port: UInt16(destination.port),
                    token: token,
                    pinnedFingerprint: destination.pinnedFingerprint
                )
                silodClient = client
                runBackup(client: client, gatewayAddress: gatewayAddress, pairingFileData: pairingFileData, remoteRoot: destination.remotePath)
            } catch {
                finish(.failed("couldn't connect to silod: \(error.localizedDescription)", activity: [], debugLog: liveDebugLog))
            }
        }
    }

    /// Asks mobilebackup2 to stop. Safe by construction: silod only
    /// publishes a file once its whole-content hash is verified on
    /// CloseFile, so a file mid-transfer when this fires simply stays as an
    /// incomplete `.silo-part` on the server — never corrupted, never
    /// mistaken for complete, and resumable later via Stat.
    func cancel() {
        guard isRunning else { return }
        let token = runToken
        let activity = bridge?.recentActivity ?? []
        phase = .cancelling
        stallWatchdogTask?.cancel()
        stallWatchdogTask = nil
        bridge?.requestCancel()

        // A run wedged before its first callback will never see the flag,
        // so give it a moment and then stop waiting on it. The background
        // work unwinds on its own; nothing it can still do writes anything
        // to the device or publishes anything on the server.
        Task {
            try? await Task.sleep(nanoseconds: Self.cancelGraceSeconds * 1_000_000_000)
            guard runToken == token, !isFinished else { return }
            finish(.cancelled(activity: activity, debugLog: liveDebugLog, abandoned: true))
        }
    }

    private func runBackup(client: SilodClient, gatewayAddress: String, pairingFileData: Data, remoteRoot: String) {
        let bridge = BackupDelegateBridge(client: client, remoteRoot: remoteRoot) { [weak self] done, total, overall in
            Task { @MainActor in
                guard let self, case .running = self.phase else { return }
                self.phase = .running(bytesSent: done, batchTotal: total, overall: overall)
            }
        }
        self.bridge = bridge
        phase = .running(bytesSent: 0, batchTotal: 0, overall: 0)
        startStallWatchdog(bridge: bridge, token: runToken)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Encryption is set up on its own throwaway session, closed
            // before the real backup session opens — `mobilebackup2` does
            // not expect a password change mid-backup-session, and this
            // keeps the two concerns from ever touching the same handle.
            if BackupEncryptionStore.isEnabled, !BackupEncryptionStore.isConfirmedSetOnDevice {
                guard let password = BackupEncryptionStore.password else {
                    Task { @MainActor in
                        guard let self else { return }
                        self.finish(.failed(
                            "Backup encryption is on, but no password is set. Set a password in the \"Encryption\" section on this screen, or explicitly turn encryption off there.",
                            activity: bridge.recentActivity, debugLog: self.liveDebugLog
                        ))
                    }
                    return
                }

                DebugLog.note("Checking WillEncrypt before enabling encryption")
                switch DeviceTunnel.checkWillEncrypt(gatewayAddress: gatewayAddress, pairingFileData: pairingFileData) {
                case .failure(let message):
                    Task { @MainActor in
                        guard let self else { return }
                        self.finish(.failed("Couldn't check the device's encryption state: \(message)", activity: bridge.recentActivity, debugLog: self.liveDebugLog))
                    }
                    return

                case .success(true):
                    // The device already reports a password set — from
                    // Finder/iTunes, or a previous Silo install that lost
                    // local state — and Silo has no proof the saved
                    // password is the real one. A backup would still
                    // "succeed" here (the device encrypts with whatever it
                    // already has), but that's exactly the trap: a
                    // confidently successful backup nobody can actually
                    // open later, if the remembered password turns out
                    // wrong. Silo's own UI verifies this with a real
                    // round-trip (`BackupPasswordVerifier`, a password
                    // swap-and-restore) *before* a run starts and sets
                    // `isConfirmedSetOnDevice` only on real proof — reaching
                    // this branch unconfirmed means that check was skipped,
                    // so fail rather than gamble a real run on it.
                    Task { @MainActor in
                        guard let self else { return }
                        self.finish(.failed(
                            "The device already has backup encryption on, but the password saved in SideBack hasn't been confirmed against the real device yet. Go back to the \"Encryption\" section and confirm the current password before starting — otherwise the backup risks coming out unreadable.",
                            activity: bridge.recentActivity, debugLog: self.liveDebugLog
                        ))
                    }
                    return

                case .success(false):
                    DebugLog.note("WillEncrypt=false, opening a separate session to enable encryption")
                    let pwSessionResult = DeviceTunnel.openBackupSession(gatewayAddress: gatewayAddress, pairingFileData: pairingFileData)
                    guard case .success(let pwSession) = pwSessionResult, let pwClient = pwSession.clientHandle else {
                        if case .failure(let message) = pwSessionResult {
                            Task { @MainActor in
                                guard let self else { return }
                                self.finish(.failed("couldn't open a session to enable encryption: \(message)", activity: bridge.recentActivity, debugLog: self.liveDebugLog))
                            }
                        }
                        return
                    }
                    let changeResult = BackupRunner.changePassword(
                        client: pwClient, backupRoot: pwSession.udid, oldPassword: nil, newPassword: password, bridge: bridge
                    )
                    pwSession.close()
                    if case .failure(let message) = changeResult {
                        Task { @MainActor in
                            guard let self else { return }
                            self.finish(.failed(
                                "Couldn't enable backup encryption: \(message).",
                                activity: bridge.recentActivity, debugLog: self.liveDebugLog
                            ))
                        }
                        return
                    }
                    BackupEncryptionStore.isConfirmedSetOnDevice = true
                    // NOTE for whoever builds real incremental resume on
                    // top of `list_dir`: turning encryption on/off changes
                    // Manifest.plist and the file-level keys, so files from
                    // a backup made under the *previous* encryption state
                    // are not the same content the device will produce now,
                    // even at identical paths. `list_dir`-based file
                    // skipping must not treat those as already-present —
                    // this needs the server to know which encryption state
                    // produced what it's holding, which it does not track
                    // yet. Free right now only because no backup has ever
                    // completed, so there is nothing stale to serve.
                    DebugLog.note("Backup encryption enabled (changing encryption state makes previous files on the server unusable for incremental resume), opening a separate session for the actual backup")
                }
            }

            let sessionResult = DeviceTunnel.openBackupSession(gatewayAddress: gatewayAddress, pairingFileData: pairingFileData)
            guard case .success(let session) = sessionResult else {
                if case .failure(let message) = sessionResult {
                    Task { @MainActor in
                        guard let self else { return }
                        self.finish(.failed("couldn't open mobilebackup2: \(message)", activity: bridge.recentActivity, debugLog: self.liveDebugLog))
                    }
                }
                return
            }
            guard let clientHandle = session.clientHandle else {
                session.close()
                Task { @MainActor in
                    guard let self else { return }
                    self.finish(.failed("mobilebackup2 session without a handle", activity: bridge.recentActivity, debugLog: self.liveDebugLog))
                }
                return
            }

            let lockNote = session.isSyncLockHeld
                ? "Sync lock taken — the device won't be distracted by its own work."
                : "Sync lock NOT held\(session.syncLockFailure.map { ": \($0)" } ?? "") — long stalls are possible."
            Task { @MainActor in self?.syncLockStatus = lockNote }

            Self.writeEncryptionMetadata(bridge: bridge)

            DebugLog.note("Phase: mobilebackup2_backup started")
            let outcome = BackupRunner.run(
                client: clientHandle,
                backupRoot: session.udid,
                deviceUUID: session.udid,
                bridge: bridge
            )
            DebugLog.note("Phase: mobilebackup2_backup returned, closing session")
            session.close()

            Task { @MainActor in
                guard let self else { return }
                switch outcome {
                case .completed:
                    self.finish(.completed)
                case .cancelled:
                    self.finish(.cancelled(activity: bridge.recentActivity, debugLog: self.liveDebugLog, abandoned: false))
                case .failed(let message):
                    self.finish(.failed(message, activity: bridge.recentActivity, debugLog: self.liveDebugLog))
                }
            }
        }
    }

    /// Polls `bridge.secondsSinceLastActivity` rather than driving off a
    /// timer that resets on progress, so it survives phases (directory
    /// creation, small-file bursts) that legitimately go a while between
    /// delegate calls without mistaking that for a stall.
    private func startStallWatchdog(bridge: BackupDelegateBridge, token: Int) {
        stallWatchdogTask?.cancel()
        stallWatchdogTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                guard self.runToken == token, !self.isFinished else { return }
                if case .cancelling = self.phase { return }
                if bridge.secondsSinceLastActivity > Self.stallTimeoutSeconds {
                    self.failDueToStall(bridge: bridge)
                    return
                }
            }
        }
    }

    /// A run stuck this long isn't slow, it's wedged — see
    /// `stallTimeoutSeconds`. The underlying background thread stays parked
    /// in its blocked read (same trade-off as an abandoned cancel); nothing
    /// it can still do writes to the device or publishes anything on the
    /// server, so ending the run here loses at most the file mid-transfer,
    /// which stays a resumable draft.
    private func failDueToStall(bridge: BackupDelegateBridge) {
        guard !isFinished else { return }
        bridge.requestCancel()
        finish(.failed(
            "The connection stalled — no response from the tunnel for over \(Int(Self.stallTimeoutSeconds)) seconds. The file that was transferring stayed a draft on the server, nothing was lost — try running it again.",
            activity: bridge.recentActivity,
            debugLog: liveDebugLog
        ))
    }

    /// Writes a `.silo-meta` file next to the backup recording whether this
    /// run was encrypted and, if so, a SHA-256 hash of the password (never
    /// the password itself) — not the running state, the server's. Cheap
    /// insurance for whoever eventually builds real `list_dir`-based
    /// incremental resume: without this, there is no way for the server to
    /// tell "these files were encrypted with the password now in use" from
    /// "these files predate a password change", and silently treating the
    /// two the same would serve a device files that don't match what it
    /// thinks is already backed up. Best-effort: a failure here doesn't
    /// abort the backup itself.
    private nonisolated static func writeEncryptionMetadata(bridge: BackupDelegateBridge) {
        let isEncrypted = BackupEncryptionStore.isEnabled
        let passwordHash = isEncrypted
            ? BackupEncryptionStore.password.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
            : nil
        let hashField = passwordHash.map { "\"\($0)\"" } ?? "null"
        let json = "{\"encrypted\":\(isEncrypted),\"password_sha256\":\(hashField)}"
        if case .failure(let error) = bridge.createFileWrite(".silo-meta") {
            DebugLog.note("Couldn't write .silo-meta: \(error)")
            return
        }
        if case .failure(let error) = bridge.writeChunk(".silo-meta", Data(json.utf8)) {
            DebugLog.note("Couldn't write .silo-meta: \(error)")
            return
        }
        if case .failure(let error) = bridge.closeFile(".silo-meta") {
            DebugLog.note("Couldn't write .silo-meta: \(error)")
        }
    }

    private func finish(_ phase: Phase) {
        guard !isFinished else { return }
        isFinished = true
        stallWatchdogTask?.cancel()
        stallWatchdogTask = nil
        UIApplication.shared.isIdleTimerDisabled = false
        BackgroundKeepAlive.shared.stop()
        self.phase = phase
        bridge = nil
        let client = silodClient
        silodClient = nil
        Task { await client?.close() }
    }
}
