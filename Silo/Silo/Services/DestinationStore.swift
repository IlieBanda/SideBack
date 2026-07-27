import Foundation
import Combine

/// Persists the non-secret half of `BackupDestination` (host/port/username/path)
/// to UserDefaults. The password lives only in `KeychainStore`.
final class DestinationStore: ObservableObject {
    @Published var destination: BackupDestination {
        didSet { save() }
    }

    private static let defaultsKey = "silo.destination"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(BackupDestination.self, from: data) {
            destination = decoded
        } else {
            destination = BackupDestination()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(destination) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
