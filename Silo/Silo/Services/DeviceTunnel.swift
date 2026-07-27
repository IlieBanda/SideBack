import Foundation

/// One service the device advertises over RSD.
struct RsdServiceInfo: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let port: UInt16
    let entitlement: String?
    let usesRemoteXPC: Bool
    let serviceVersion: Int64?

    /// The backup service Silo is ultimately built around.
    var isMobileBackup2: Bool {
        name.localizedCaseInsensitiveContains("mobilebackup2")
    }
}

/// Everything Silo learned in one tunnel session.
struct TunnelSnapshot {
    let deviceUUID: String
    let protocolVersion: Int
    let services: [RsdServiceInfo]
    /// Result of actually opening the mobilebackup2 service — nil if the
    /// service wasn't advertised at all.
    let backupServiceStatus: BackupServiceStatus?

    enum BackupServiceStatus {
        case connected
        case failed(String)
    }
}

/// Establishes the iOS 17+ loopback tunnel and interrogates the device
/// through it: direct TCP -> RPPairing (authenticated with the device's
/// remote pairing file) -> CoreDeviceProxy -> RSD handshake -> service
/// discovery.
///
/// Protocol notes learned the hard way on real hardware, kept so nobody
/// re-derives them:
/// - The port is **49152**, not 62078. 62078 is the classic lockdownd port
///   and resets this protocol's connections.
/// - StosVPN/LocalDevVPN is a pure NAT-style packet rewriter (10.7.0.0 <->
///   10.7.0.1), not a proxy service. Whatever answers is the device itself.
/// - The pairing file is the modern `RpPairingFile` schema (`identifier`,
///   `private_key`, `public_key`, `alt_irk`) parsed by
///   `rp_pairing_file_from_bytes` — NOT the classic libimobiledevice
///   `PairingFile` (`DeviceCertificate`/`HostPrivateKey`/...) that
///   `idevice_start_session` wants.
enum DeviceTunnel {
    /// Fixed port used by StikDebug's own working implementation.
    static let port: UInt16 = 49152
    private static let maxAttempts = 3
    private static let retryDelay: TimeInterval = 0.4

    /// `jktcp`'s advertised-window scale exponent (raw TCP Window Scale
    /// value, 0-14; advertised window is `65534 << bits`). A `Rust
    /// std::env::var` read is otherwise a dead knob on iOS — no shell to
    /// export into, no real effect outside an Xcode-launched debug session
    /// — so this is a UserDefaults-backed setting applied via `setenv`
    /// right before every tunnel creation, not a constant pretending to be
    /// configurable.
    static var jktcpWindowScaleBits: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: "silo.jktcp.wscaleBits")
            return value == 0 && UserDefaults.standard.object(forKey: "silo.jktcp.wscaleBits") == nil ? 2 : value
        }
        set { UserDefaults.standard.set(max(0, min(14, newValue)), forKey: "silo.jktcp.wscaleBits") }
    }

    private static func applyJktcpTuning() {
        setenv("SILO_JKTCP_WSCALE_BITS", String(jktcpWindowScaleBits), 1)
    }

    enum Result {
        case success(TunnelSnapshot)
        case failure(String)
    }

    static func inspect(gatewayAddress: String, pairingFileData: Data) -> Result {
        var lastFailure = "unknown error"
        for attempt in 1...maxAttempts {
            switch attemptOnce(gatewayAddress: gatewayAddress, pairingFileData: pairingFileData, attempt: attempt) {
            case .success(let snapshot):
                return .success(snapshot)
            case .failure(let message):
                lastFailure = message
                if attempt < maxAttempts {
                    Thread.sleep(forTimeInterval: retryDelay)
                }
            }
        }
        return .failure("After \(maxAttempts) attempts: \(lastFailure)")
    }

    private static func attemptOnce(gatewayAddress: String, pairingFileData: Data, attempt: Int) -> Result {
        // 1. Parse the remote pairing file.
        var pairingHandle: OpaquePointer?
        let pairingError = pairingFileData.withUnsafeBytes { rawBuffer -> UnsafeMutablePointer<IdeviceFfiError>? in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return rp_pairing_file_from_bytes(bytes.baseAddress, UInt(bytes.count), &pairingHandle)
        }
        if let pairingError {
            let message = errorMessage(pairingError)
            idevice_error_free(pairingError)
            return .failure("attempt \(attempt): failed to parse remote pairing file: \(message)")
        }
        guard let pairingHandle else {
            return .failure("attempt \(attempt): rp_pairing_file_from_bytes returned no handle")
        }
        defer { rp_pairing_file_free(pairingHandle) }

        // 2. Build the tunnel: TCP -> RPPairing -> CoreDeviceProxy -> RSD.
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, gatewayAddress, &addr.sin_addr) == 1 else {
            return .failure("Couldn't parse address \(gatewayAddress)")
        }

        var adapterHandle: OpaquePointer?
        var handshakeHandle: OpaquePointer?
        let label = "com.ilia.silo"

        applyJktcpTuning()
        let tunnelError = withUnsafePointer(to: &addr) { addrPtr -> UnsafeMutablePointer<IdeviceFfiError>? in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                label.withCString { labelPtr in
                    tunnel_create_rppairing(
                        sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size),
                        labelPtr, pairingHandle,
                        nil, nil,
                        &adapterHandle, &handshakeHandle
                    )
                }
            }
        }

        if let tunnelError {
            let message = errorMessage(tunnelError)
            idevice_error_free(tunnelError)
            return .failure("attempt \(attempt): tunnel_create_rppairing failed: \(message)")
        }

        guard let handshakeHandle, let adapterHandle else {
            if let adapterHandle { adapter_free(adapterHandle) }
            if let handshakeHandle { rsd_handshake_free(handshakeHandle) }
            return .failure("attempt \(attempt): tunnel created without valid handles")
        }
        // The adapter is the transport under everything below — it must stay
        // alive until all service work on this tunnel is done.
        defer {
            rsd_handshake_free(handshakeHandle)
            adapter_free(adapterHandle)
        }

        // 3. Identity.
        var uuidPtr: UnsafeMutablePointer<CChar>?
        let uuidError = rsd_get_uuid(handshakeHandle, &uuidPtr)
        if let uuidError {
            let message = errorMessage(uuidError)
            idevice_error_free(uuidError)
            return .failure("attempt \(attempt): tunnel established, but rsd_get_uuid failed: \(message)")
        }
        guard let uuidPtr else {
            return .failure("attempt \(attempt): rsd_get_uuid returned no string")
        }
        let uuid = String(cString: uuidPtr)
        idevice_string_free(uuidPtr)

        var protocolVersion: Int = 0
        if let versionError = rsd_get_protocol_version(handshakeHandle, &protocolVersion) {
            idevice_error_free(versionError)
            protocolVersion = -1
        }

        // 4. Enumerate every service the device advertises.
        let services = fetchServices(handshakeHandle)

        // 5. If mobilebackup2 is advertised, prove we can actually open it.
        //    This only opens the service channel — it does NOT start,
        //    read, or write any backup. `mobilebackup2_backup` is the call
        //    that would touch real data, and it is deliberately not used.
        var backupStatus: TunnelSnapshot.BackupServiceStatus?
        if services.contains(where: { $0.isMobileBackup2 }) {
            var backupClient: OpaquePointer?
            if let backupError = mobilebackup2_connect_rsd(adapterHandle, handshakeHandle, &backupClient) {
                let message = errorMessage(backupError)
                idevice_error_free(backupError)
                backupStatus = .failed(message)
            } else if let backupClient {
                mobilebackup2_client_free(backupClient)
                backupStatus = .connected
            } else {
                backupStatus = .failed("connect returned an empty handle")
            }
        }

        return .success(TunnelSnapshot(
            deviceUUID: uuid,
            protocolVersion: protocolVersion,
            services: services,
            backupServiceStatus: backupStatus
        ))
    }

    // MARK: - Backup encryption state

    enum WillEncryptResult {
        case success(Bool)
        case failure(String)
    }

    /// Whether the device already has a backup password set, read from
    /// lockdown (`com.apple.mobile.backup` / `WillEncrypt`) — the same way
    /// the reference `idevicebackup2` checks it. `mobilebackup2`'s own
    /// `check_backup_encryption` is an unimplemented stub in this crate, so
    /// this is the only real source of truth.
    ///
    /// This matters because `mobilebackup2_change_password` needs the
    /// device's *current* password to change it (an empty "old" password
    /// only works the very first time encryption is turned on). Calling it
    /// blind on a device that already has a password set — from Finder,
    /// from a previous Silo install, from anywhere — fails, and calling it
    /// with the wrong "old" guess risks confusing the device's encryption
    /// state. Always check first.
    static func checkWillEncrypt(gatewayAddress: String, pairingFileData: Data) -> WillEncryptResult {
        var lastFailure = "unknown error"
        for attempt in 1...maxAttempts {
            switch checkWillEncryptOnce(gatewayAddress: gatewayAddress, pairingFileData: pairingFileData, attempt: attempt) {
            case .success(let value): return .success(value)
            case .failure(let message):
                lastFailure = message
                if attempt < maxAttempts { Thread.sleep(forTimeInterval: retryDelay) }
            }
        }
        return .failure("After \(maxAttempts) attempts: \(lastFailure)")
    }

    private static func checkWillEncryptOnce(gatewayAddress: String, pairingFileData: Data, attempt: Int) -> WillEncryptResult {
        var pairingHandle: OpaquePointer?
        let pairingError = pairingFileData.withUnsafeBytes { rawBuffer -> UnsafeMutablePointer<IdeviceFfiError>? in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return rp_pairing_file_from_bytes(bytes.baseAddress, UInt(bytes.count), &pairingHandle)
        }
        if let pairingError {
            let message = errorMessage(pairingError)
            idevice_error_free(pairingError)
            return .failure("attempt \(attempt): failed to parse remote pairing file: \(message)")
        }
        guard let pairingHandle else {
            return .failure("attempt \(attempt): rp_pairing_file_from_bytes returned no handle")
        }
        defer { rp_pairing_file_free(pairingHandle) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, gatewayAddress, &addr.sin_addr) == 1 else {
            return .failure("Couldn't parse address \(gatewayAddress)")
        }

        var adapterHandle: OpaquePointer?
        var handshakeHandle: OpaquePointer?
        let label = "com.ilia.silo"

        applyJktcpTuning()
        let tunnelError = withUnsafePointer(to: &addr) { addrPtr -> UnsafeMutablePointer<IdeviceFfiError>? in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                label.withCString { labelPtr in
                    tunnel_create_rppairing(
                        sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size),
                        labelPtr, pairingHandle,
                        nil, nil,
                        &adapterHandle, &handshakeHandle
                    )
                }
            }
        }
        if let tunnelError {
            let message = errorMessage(tunnelError)
            idevice_error_free(tunnelError)
            return .failure("attempt \(attempt): tunnel_create_rppairing failed: \(message)")
        }
        guard let handshakeHandle, let adapterHandle else {
            if let adapterHandle { adapter_free(adapterHandle) }
            if let handshakeHandle { rsd_handshake_free(handshakeHandle) }
            return .failure("attempt \(attempt): tunnel created without valid handles")
        }
        defer {
            rsd_handshake_free(handshakeHandle)
            adapter_free(adapterHandle)
        }

        var lockdownClient: OpaquePointer?
        if let lockdownError = lockdownd_connect_rsd(adapterHandle, handshakeHandle, &lockdownClient) {
            let message = errorMessage(lockdownError)
            idevice_error_free(lockdownError)
            return .failure("attempt \(attempt): lockdownd_connect_rsd failed: \(message)")
        }
        guard let lockdownClient else {
            return .failure("attempt \(attempt): lockdownd_connect_rsd returned an empty handle")
        }
        defer { lockdownd_client_free(lockdownClient) }

        var plist: plist_t?
        let valueError = "WillEncrypt".withCString { keyPtr -> UnsafeMutablePointer<IdeviceFfiError>? in
            "com.apple.mobile.backup".withCString { domainPtr in
                lockdownd_get_value(lockdownClient, keyPtr, domainPtr, &plist)
            }
        }
        if let valueError {
            let message = errorMessage(valueError)
            idevice_error_free(valueError)
            return .failure("attempt \(attempt): lockdownd_get_value(WillEncrypt) failed: \(message)")
        }
        guard let plist else {
            // Absent key: seen on devices that have never had a backup
            // password touched. Treat as "not encrypted" — the safe,
            // conservative default that still lets change_password's first
            // (old: nil) call succeed.
            return .success(false)
        }
        defer { plist_free(plist) }
        var raw: UInt8 = 0
        plist_get_bool_val(plist, &raw)
        return .success(raw != 0)
    }

    // MARK: - Storage estimate

    /// A rough upper bound on backup size, queried before starting: how much
    /// space is actually used on the device. `mobilebackup2` gives no way to
    /// learn the real total ahead of time — confirmed against
    /// libimobiledevice itself, whose own maintainers answer "no" to this
    /// exact question (github.com/libimobiledevice/libimobiledevice#353) and
    /// whose `idevicebackup2` shows the same non-byte-proportional overall
    /// percentage Silo does, taken verbatim from the device's own
    /// `DLMessageUploadFiles` payload. Used storage is the best available
    /// proxy: the real backup is usually somewhat smaller (some caches and
    /// system data are excluded), never larger.
    enum StorageEstimateResult {
        case success(UInt64)
        case failure(String)
    }

    static func estimateUsedStorage(gatewayAddress: String, pairingFileData: Data) -> StorageEstimateResult {
        var lastFailure = "unknown error"
        for attempt in 1...maxAttempts {
            switch estimateUsedStorageOnce(gatewayAddress: gatewayAddress, pairingFileData: pairingFileData, attempt: attempt) {
            case .success(let bytes):
                return .success(bytes)
            case .failure(let message):
                lastFailure = message
                if attempt < maxAttempts { Thread.sleep(forTimeInterval: retryDelay) }
            }
        }
        return .failure("After \(maxAttempts) attempts: \(lastFailure)")
    }

    private static func estimateUsedStorageOnce(gatewayAddress: String, pairingFileData: Data, attempt: Int) -> StorageEstimateResult {
        var pairingHandle: OpaquePointer?
        let pairingError = pairingFileData.withUnsafeBytes { rawBuffer -> UnsafeMutablePointer<IdeviceFfiError>? in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return rp_pairing_file_from_bytes(bytes.baseAddress, UInt(bytes.count), &pairingHandle)
        }
        if let pairingError {
            let message = errorMessage(pairingError)
            idevice_error_free(pairingError)
            return .failure("attempt \(attempt): failed to parse remote pairing file: \(message)")
        }
        guard let pairingHandle else {
            return .failure("attempt \(attempt): rp_pairing_file_from_bytes returned no handle")
        }
        defer { rp_pairing_file_free(pairingHandle) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, gatewayAddress, &addr.sin_addr) == 1 else {
            return .failure("Couldn't parse address \(gatewayAddress)")
        }

        var adapterHandle: OpaquePointer?
        var handshakeHandle: OpaquePointer?
        let label = "com.ilia.silo"

        applyJktcpTuning()
        let tunnelError = withUnsafePointer(to: &addr) { addrPtr -> UnsafeMutablePointer<IdeviceFfiError>? in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                label.withCString { labelPtr in
                    tunnel_create_rppairing(
                        sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size),
                        labelPtr, pairingHandle,
                        nil, nil,
                        &adapterHandle, &handshakeHandle
                    )
                }
            }
        }

        if let tunnelError {
            let message = errorMessage(tunnelError)
            idevice_error_free(tunnelError)
            return .failure("attempt \(attempt): tunnel_create_rppairing failed: \(message)")
        }
        guard let handshakeHandle, let adapterHandle else {
            if let adapterHandle { adapter_free(adapterHandle) }
            if let handshakeHandle { rsd_handshake_free(handshakeHandle) }
            return .failure("attempt \(attempt): tunnel created without valid handles")
        }
        defer {
            rsd_handshake_free(handshakeHandle)
            adapter_free(adapterHandle)
        }

        var lockdownClient: OpaquePointer?
        if let lockdownError = lockdownd_connect_rsd(adapterHandle, handshakeHandle, &lockdownClient) {
            let message = errorMessage(lockdownError)
            idevice_error_free(lockdownError)
            return .failure("attempt \(attempt): lockdownd_connect_rsd failed: \(message)")
        }
        guard let lockdownClient else {
            return .failure("attempt \(attempt): lockdownd_connect_rsd returned an empty handle")
        }
        defer { lockdownd_client_free(lockdownClient) }

        guard let total = diskUsageValue(lockdownClient, key: "TotalDataCapacity") else {
            return .failure("attempt \(attempt): couldn't get TotalDataCapacity")
        }
        guard let available = diskUsageValue(lockdownClient, key: "TotalDataAvailable") else {
            return .failure("attempt \(attempt): couldn't get TotalDataAvailable")
        }
        guard total >= available else {
            return .failure("attempt \(attempt): unexpected disk values (total=\(total), available=\(available))")
        }
        return .success(total - available)
    }

    private static func diskUsageValue(_ client: OpaquePointer, key: String) -> UInt64? {
        var plist: plist_t?
        let error = key.withCString { keyPtr -> UnsafeMutablePointer<IdeviceFfiError>? in
            "com.apple.disk_usage".withCString { domainPtr in
                lockdownd_get_value(client, keyPtr, domainPtr, &plist)
            }
        }
        if let error {
            idevice_error_free(error)
            return nil
        }
        guard let plist else { return nil }
        defer { plist_free(plist) }
        var value: UInt64 = 0
        plist_get_uint_val(plist, &value)
        return value
    }

    private static func fetchServices(_ handshake: OpaquePointer) -> [RsdServiceInfo] {
        var arrayPtr: UnsafeMutablePointer<CRsdServiceArray>?
        if let error = rsd_get_services(handshake, &arrayPtr) {
            idevice_error_free(error)
            return []
        }
        guard let arrayPtr else { return [] }
        defer { rsd_free_services(arrayPtr) }

        let array = arrayPtr.pointee
        guard let servicesBase = array.services else { return [] }

        var result: [RsdServiceInfo] = []
        result.reserveCapacity(array.count)

        for index in 0..<array.count {
            let service = servicesBase[index]
            guard let namePtr = service.name else { continue }

            let entitlement = service.entitlement.map { String(cString: $0) }
            result.append(RsdServiceInfo(
                name: String(cString: namePtr),
                port: service.port,
                entitlement: (entitlement?.isEmpty ?? true) ? nil : entitlement,
                usesRemoteXPC: service.uses_remote_xpc,
                serviceVersion: service.service_version >= 0 ? service.service_version : nil
            ))
        }

        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func errorMessage(_ error: UnsafeMutablePointer<IdeviceFfiError>) -> String {
        guard let messagePtr = error.pointee.message else {
            return "code \(error.pointee.code), sub_code \(error.pointee.sub_code)"
        }
        return "\(String(cString: messagePtr)) (code \(error.pointee.code))"
    }

    // MARK: - Live session (for an actual backup run)

    enum SessionResult {
        case success(BackupSession)
        case failure(String)
    }

    /// Same handshake as `inspect`, but keeps the tunnel and mobilebackup2
    /// client open instead of closing them right after the probe — needed
    /// for an actual `mobilebackup2_backup` call, which streams for the
    /// whole duration of a backup.
    static func openBackupSession(gatewayAddress: String, pairingFileData: Data) -> SessionResult {
        var pairingHandle: OpaquePointer?
        let pairingError = pairingFileData.withUnsafeBytes { rawBuffer -> UnsafeMutablePointer<IdeviceFfiError>? in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return rp_pairing_file_from_bytes(bytes.baseAddress, UInt(bytes.count), &pairingHandle)
        }
        if let pairingError {
            let message = errorMessage(pairingError)
            idevice_error_free(pairingError)
            return .failure("failed to parse remote pairing file: \(message)")
        }
        guard let pairingHandle else {
            return .failure("rp_pairing_file_from_bytes returned no handle")
        }
        defer { rp_pairing_file_free(pairingHandle) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, gatewayAddress, &addr.sin_addr) == 1 else {
            return .failure("Couldn't parse address \(gatewayAddress)")
        }

        var adapterHandle: OpaquePointer?
        var handshakeHandle: OpaquePointer?
        let label = "com.ilia.silo"

        applyJktcpTuning()
        let tunnelError = withUnsafePointer(to: &addr) { addrPtr -> UnsafeMutablePointer<IdeviceFfiError>? in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                label.withCString { labelPtr in
                    tunnel_create_rppairing(
                        sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size),
                        labelPtr, pairingHandle,
                        nil, nil,
                        &adapterHandle, &handshakeHandle
                    )
                }
            }
        }
        if let tunnelError {
            let message = errorMessage(tunnelError)
            idevice_error_free(tunnelError)
            return .failure("tunnel_create_rppairing failed: \(message)")
        }
        guard let handshakeHandle, let adapterHandle else {
            if let adapterHandle { adapter_free(adapterHandle) }
            if let handshakeHandle { rsd_handshake_free(handshakeHandle) }
            return .failure("tunnel created without valid handles")
        }

        var uuidPtr: UnsafeMutablePointer<CChar>?
        let uuidError = rsd_get_uuid(handshakeHandle, &uuidPtr)
        if let uuidError {
            let message = errorMessage(uuidError)
            idevice_error_free(uuidError)
            rsd_handshake_free(handshakeHandle)
            adapter_free(adapterHandle)
            return .failure("rsd_get_uuid failed: \(message)")
        }
        guard let uuidPtr else {
            rsd_handshake_free(handshakeHandle)
            adapter_free(adapterHandle)
            return .failure("rsd_get_uuid returned no string")
        }
        let uuid = String(cString: uuidPtr)
        idevice_string_free(uuidPtr)

        // The RSD UUID above is an ECID-derived identifier, not the
        // device's classic UDID — on modern devices both happen to look
        // like UUIDs, so it's easy to assume they're the same value. They
        // aren't. mobilebackup2 needs the real UDID (from RSD's own
        // Properties dictionary), confirmed by pulling it out separately
        // and having a real backup attempt succeed past the point where
        // the ECID uuid was rejected.
        var udidPtr: UnsafeMutablePointer<CChar>?
        let udidError = rsd_get_unique_device_id(handshakeHandle, &udidPtr)
        if let udidError {
            let message = errorMessage(udidError)
            idevice_error_free(udidError)
            rsd_handshake_free(handshakeHandle)
            adapter_free(adapterHandle)
            return .failure("rsd_get_unique_device_id failed: \(message)")
        }
        guard let udidPtr else {
            rsd_handshake_free(handshakeHandle)
            adapter_free(adapterHandle)
            return .failure("rsd_get_unique_device_id returned no string")
        }
        let udid = String(cString: udidPtr)
        idevice_string_free(udidPtr)

        // Take the iTunes sync lock *before* mobilebackup2 is started, the
        // way `idevicebackup2` does. The point of the lock is to tell the
        // device a sync is beginning; announcing it after BackupAgent2 is
        // already running announces nothing. Best effort — a device that
        // refuses the lock still gets backed up.
        let syncLock = SyncLock()
        if SyncLock.isEnabled {
            syncLock.acquire(adapter: adapterHandle, handshake: handshakeHandle)
        } else {
            DebugLog.note("SyncLock: disabled in settings, skipping")
        }

        DebugLog.note("Connecting to mobilebackup2")
        var backupClient: OpaquePointer?
        if let backupError = mobilebackup2_connect_rsd(adapterHandle, handshakeHandle, &backupClient) {
            let message = errorMessage(backupError)
            idevice_error_free(backupError)
            syncLock.release()
            rsd_handshake_free(handshakeHandle)
            adapter_free(adapterHandle)
            // Report the lock outcome alongside the failure: when the
            // connect fails there is no session to read it off later, and
            // whether the lock was taken is the first thing worth knowing.
            let lockNote = syncLock.isHeld
                ? " (sync lock was held)"
                : " (sync lock not held\(syncLock.failureReason.map { ": \($0)" } ?? ""))"
            return .failure("mobilebackup2_connect_rsd failed: \(message)\(lockNote)")
        }
        guard let backupClient else {
            syncLock.release()
            rsd_handshake_free(handshakeHandle)
            adapter_free(adapterHandle)
            return .failure("connect returned an empty handle")
        }

        // mobilebackup2_connect_rsd never learns the device's UDID the way
        // the classic lockdownd connect path does, so a real backup call
        // ships a null target identifier — on-device BackupAgent2 asserts
        // ("Backup target device ID (null) doesn't match actual ...") and
        // tears the connection down. Confirmed via Console.app logs on
        // real hardware. Fill it in explicitly before returning the client.
        if let setError = udid.withCString({ mobilebackup2_set_udid(backupClient, $0) }) {
            let message = errorMessage(setError)
            idevice_error_free(setError)
            mobilebackup2_client_free(backupClient)
            rsd_handshake_free(handshakeHandle)
            adapter_free(adapterHandle)
            return .failure("mobilebackup2_set_udid failed: \(message)")
        }

        return .success(BackupSession(
            adapterHandle: adapterHandle,
            handshakeHandle: handshakeHandle,
            backupClient: backupClient,
            deviceUUID: uuid,
            udid: udid,
            syncLock: syncLock
        ))
    }
}

/// Owns the live handles behind an open mobilebackup2 session. Must be
/// closed (or dropped) exactly once — `close()` is idempotent so callers
/// don't have to track whether it already ran.
final class BackupSession {
    private var adapterHandle: OpaquePointer?
    private var handshakeHandle: OpaquePointer?
    private var backupClient: OpaquePointer?
    /// Held for the lifetime of the session so the device treats this as a
    /// real sync rather than interleaving its own work with ours.
    private let syncLock: SyncLock
    /// Why the iTunes sync lock could not be taken, if it could not. The
    /// backup still runs without it, just with the device free to stall.
    var syncLockFailure: String? { syncLock.isHeld ? nil : syncLock.failureReason }
    var isSyncLockHeld: Bool { syncLock.isHeld }
    /// RSD/ECID-style identifier — display only, not what mobilebackup2 checks.
    let deviceUUID: String
    /// The device's real UDID — what `mobilebackup2_backup`'s target/source
    /// identifiers must actually match.
    let udid: String

    fileprivate init(adapterHandle: OpaquePointer, handshakeHandle: OpaquePointer, backupClient: OpaquePointer, deviceUUID: String, udid: String, syncLock: SyncLock) {
        self.syncLock = syncLock
        self.adapterHandle = adapterHandle
        self.handshakeHandle = handshakeHandle
        self.backupClient = backupClient
        self.deviceUUID = deviceUUID
        self.udid = udid
    }

    /// The handle `BackupRunner.run` calls `mobilebackup2_backup` with.
    var clientHandle: OpaquePointer? { backupClient }

    func close() {
        // Before the transport goes away: the lock lives on AFC over this
        // same adapter, so releasing it afterwards would be releasing it
        // over a dead socket.
        syncLock.release()
        if let backupClient {
            // Say goodbye over DeviceLink before dropping the socket.
            // BackupAgent2 serves one session at a time and holds onto a
            // session whose socket merely vanished, so skipping this leaves
            // the *next* attempt sitting silent forever waiting for a
            // version exchange the device will never send.
            if let error = mobilebackup2_disconnect(backupClient) {
                idevice_error_free(error)
            }
            mobilebackup2_client_free(backupClient)
            self.backupClient = nil
        }
        if let handshakeHandle {
            rsd_handshake_free(handshakeHandle)
            self.handshakeHandle = nil
        }
        if let adapterHandle {
            adapter_free(adapterHandle)
            self.adapterHandle = nil
        }
    }

    deinit { close() }
}
