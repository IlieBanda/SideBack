import CryptoKit
import Foundation
import Network

/// TLS client for a silod destination.
///
/// silod defaults to a self-signed certificate (it's the user's own box, not
/// a public web server), so trust is established by pinning the certificate
/// fingerprint on first connect and refusing any change afterwards. That
/// catches a swapped server without demanding the user run a CA.
actor SilodClient {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.ilia.silo.silod")

    /// SHA-256 of the server's leaf certificate, as seen on this connection.
    private(set) var certificateFingerprint: String?

    private init(connection: NWConnection) {
        self.connection = connection
    }

    // MARK: - Connecting

    static func connect(
        host: String,
        port: UInt16,
        token: String,
        pinnedFingerprint: String?
    ) async throws -> SilodClient {
        let observed = FingerprintBox()

        let tls = NWProtocolTLS.Options()
        let verifyQueue = DispatchQueue(label: "com.ilia.silo.tls-verify")
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, trustRef, complete in
                let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
                guard
                    let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                    let leaf = chain.first
                else {
                    complete(false)
                    return
                }

                let der = SecCertificateCopyData(leaf) as Data
                let fingerprint = Self.fingerprint(of: der)
                observed.value = fingerprint

                // Trust on first use, then pin. An unexpected change means a
                // different server is answering — refuse rather than warn.
                if let pinned = pinnedFingerprint, pinned != fingerprint {
                    complete(false)
                    return
                }
                complete(true)
            },
            verifyQueue
        )

        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw SilodError.badConfiguration("invalid port \(port)")
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: parameters
        )
        let client = SilodClient(connection: connection)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = ResumeGuard()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume() }
                case .failed(let error):
                    if resumed.claim() {
                        continuation.resume(throwing: SilodError.transport(Self.describe(error, pinned: pinnedFingerprint)))
                    }
                case .cancelled:
                    if resumed.claim() {
                        continuation.resume(throwing: SilodError.transport("connection cancelled"))
                    }
                default:
                    break
                }
            }
            connection.start(queue: client.queue)
        }

        await client.setFingerprint(observed.value)
        try await client.handshake(token: token)
        return client
    }

    private func setFingerprint(_ value: String?) {
        certificateFingerprint = value
    }

    private func handshake(token: String) async throws {
        let response = try await call(.hello(version: 1, token: Data(token.utf8)))
        switch response {
        case .ok:
            return
        case .error(let message):
            throw SilodError.server(message)
        default:
            throw SilodError.server("unexpected response to handshake")
        }
    }

    func close() {
        connection.cancel()
    }

    // MARK: - Request / response

    func call(_ request: SilodRequest) async throws -> SilodResponse {
        let payload = request.encoded()
        var frame = Data()
        // Length prefix is big-endian, unlike the payload's little-endian body.
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)

        try await send(frame)

        let lengthBytes = try await receive(exactly: 4)
        let length = lengthBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard length <= 16 * 1024 * 1024 else {
            throw SilodError.transport("server sent a \(length)-byte frame — over the limit")
        }
        let body = try await receive(exactly: Int(length))
        return try SilodResponse.decode(body)
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: SilodError.transport(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receive(exactly count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: SilodError.transport(error.localizedDescription))
                    return
                }
                guard let data, data.count == count else {
                    continuation.resume(throwing: SilodError.transport(
                        isComplete ? "server closed the connection" : "received an incomplete response"
                    ))
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    // MARK: - Helpers

    static func fingerprint(of der: Data) -> String {
        SHA256.hash(data: der)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }

    private static func describe(_ error: NWError, pinned: String?) -> String {
        // A pinned mismatch surfaces as a generic TLS failure; say so plainly
        // instead of leaving the user staring at "-9807".
        if pinned != nil, case .tls = error {
            return "TLS rejected: certificate fingerprint didn't match the saved one"
        }
        return error.localizedDescription
    }
}

enum SilodError: Error, LocalizedError {
    case badConfiguration(String)
    case transport(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .badConfiguration(let message): return message
        case .transport(let message): return "network: \(message)"
        case .server(let message): return "server: \(message)"
        }
    }
}

/// Lets the TLS verify block, which runs on its own queue, hand a value back.
private final class FingerprintBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    var value: String? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

/// `stateUpdateHandler` can fire more than once; a continuation may only be
/// resumed once.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.withLock {
            if used { return false }
            used = true
            return true
        }
    }
}
