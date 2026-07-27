import CryptoKit
import Foundation

/// Proves the whole path to a silod destination actually works, end to end,
/// before any real backup data is involved: TLS, authentication, chunked
/// write, integrity verification, read-back, and cleanup.
enum SilodHealthCheck {
    struct Report {
        let fingerprint: String?
        let steps: [String]
        let roundTripBytes: Int
    }

    /// Written and then removed; nothing device-related is transmitted.
    private static let probePath = "silo-connection-test/probe.bin"

    static func run(
        destination: BackupDestination,
        token: String
    ) async throws -> Report {
        var steps: [String] = []

        let client = try await SilodClient.connect(
            host: destination.host,
            port: UInt16(destination.port),
            token: token,
            pinnedFingerprint: destination.pinnedFingerprint
        )
        steps.append("TLS connection and authentication — ok")
        let fingerprint = await client.certificateFingerprint

        defer { Task { await client.close() } }

        // A payload big enough to span more than one chunk boundary in the
        // real transfer path, but trivially small on the wire.
        let payload = Data((0..<64_000).map { UInt8($0 % 251) })
        let payloadDigest = Data(SHA256.hash(data: payload))

        try await expectOk(await client.call(.createFileWrite(path: probePath, truncate: true)))
        for chunk in payload.chunks(of: 16_000) {
            let digest = Data(SHA256.hash(data: chunk))
            try await expectOk(await client.call(.writeChunk(path: probePath, data: chunk, hash: digest)))
        }
        try await expectOk(await client.call(.closeFile(path: probePath, hash: payloadDigest)))
        steps.append("Wrote \(payload.count) bytes with SHA-256 verification — ok")

        try await expectOk(await client.call(.openFileRead(path: probePath)))
        var readBack = Data()
        while true {
            let response = try await client.call(.readChunk(path: probePath, max: 16_000))
            if case .data(let chunk) = response {
                readBack.append(chunk)
            } else if case .eof = response {
                break
            } else if case .error(let message) = response {
                throw SilodError.server(message)
            } else {
                throw SilodError.server("unexpected response while reading")
            }
        }
        _ = try? await client.call(.closeRead(path: probePath))

        guard readBack == payload else {
            throw SilodError.server("read data didn't match what was written")
        }
        steps.append("Read back and byte-for-byte comparison — ok")

        try await expectOk(await client.call(.remove(path: probePath)))
        steps.append("Deleted the test file — ok")

        return Report(fingerprint: fingerprint, steps: steps, roundTripBytes: payload.count)
    }

    private static func expectOk(_ response: SilodResponse) throws {
        switch response {
        case .ok:
            return
        case .error(let message):
            throw SilodError.server(message)
        default:
            throw SilodError.server("expected Ok, got something else")
        }
    }
}

private extension Data {
    func chunks(of size: Int) -> [Data] {
        stride(from: 0, to: count, by: size).map { start in
            self[index(startIndex, offsetBy: start)..<index(startIndex, offsetBy: Swift.min(start + size, count))]
        }
    }
}
