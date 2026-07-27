import Foundation

/// Where a backup is streamed to: a server running `silod`, over Silo's own
/// TLS protocol. Authentication is a single shared token — the protocol has
/// no notion of a username — and the token itself lives only in Keychain.
struct BackupDestination: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var host: String = ""
    var port: Int = 9143
    var remotePath: String = "backups"

    /// SHA-256 of the server's TLS certificate, pinned on first successful
    /// connection. Not a secret — it's a public key digest — so it lives
    /// alongside the rest of the configuration rather than in Keychain.
    /// A later mismatch means a different server is answering.
    var pinnedFingerprint: String?

    var isValid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && (1...65535).contains(port)
    }
}
