import Foundation

/// Proves the user actually knows the backup password already set on the
/// device, before Silo ever spends a real backup run on data that might end
/// up unreadable.
///
/// `mobilebackup2_change_password(old: candidate, new: candidate)` is not
/// used for this — its behavior when old and new are identical isn't
/// something to rely on. Instead this swaps to a random throwaway password
/// and immediately back: if the swap-away succeeds, `candidate` was
/// correct; the swap-back then restores it. Both directions go through the
/// device, so a wrong candidate fails on the very first call and nothing
/// changes on the device at all.
enum BackupPasswordVerifier {
    enum Outcome {
        case correct
        case incorrect(String)
        case error(String)
        /// The swap-away succeeded (so `candidate` was right) but the
        /// swap-back failed — the device's password is now the random
        /// throwaway value in this case, not `candidate`. This must be
        /// surfaced to the user immediately and prominently: it is a real,
        /// currently-active password they did not choose.
        case stuckOnTemporaryPassword(String)
    }

    static func verify(
        gatewayAddress: String,
        pairingFileData: Data,
        destination: BackupDestination,
        token: String,
        candidate: String
    ) async -> Outcome {
        do {
            let client = try await SilodClient.connect(
                host: destination.host,
                port: UInt16(destination.port),
                token: token,
                pinnedFingerprint: destination.pinnedFingerprint
            )
            defer { Task { await client.close() } }

            let sessionResult = DeviceTunnel.openBackupSession(gatewayAddress: gatewayAddress, pairingFileData: pairingFileData)
            guard case .success(let session) = sessionResult, let clientHandle = session.clientHandle else {
                if case .failure(let message) = sessionResult { return .error("couldn't open session: \(message)") }
                return .error("mobilebackup2 session without a handle")
            }
            defer { session.close() }

            let bridge = BackupDelegateBridge(client: client, remoteRoot: destination.remotePath) { _, _, _ in }
            let temporary = "silo-verify-\(UUID().uuidString)"

            let swapAway = BackupRunner.changePassword(
                client: clientHandle, backupRoot: session.udid, oldPassword: candidate, newPassword: temporary, bridge: bridge
            )
            guard case .success = swapAway else {
                if case .failure(let message) = swapAway { return .incorrect(message) }
                return .incorrect("unknown error")
            }

            let swapBack = BackupRunner.changePassword(
                client: clientHandle, backupRoot: session.udid, oldPassword: temporary, newPassword: candidate, bridge: bridge
            )
            if case .failure = swapBack {
                return .stuckOnTemporaryPassword(temporary)
            }
            return .correct
        } catch {
            return .error("couldn't connect to silod: \(error.localizedDescription)")
        }
    }
}
