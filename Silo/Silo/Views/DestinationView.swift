import SwiftUI

struct DestinationView: View {
    @StateObject private var store = DestinationStore()
    @State private var token: String = ""
    @State private var isTesting = false
    @State private var report: SilodHealthCheck.Report?
    @State private var failure: String?

    private var hasToken: Bool {
        !token.isEmpty || KeychainStore.password(for: store.destination.id) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Host (e.g. 192.168.100.31)", text: $store.destination.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Stepper("Port: \(String(store.destination.port))", value: $store.destination.port, in: 1...65535)
                    TextField("Folder on server", text: $store.destination.remotePath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server")
                } footer: {
                    Text("A machine running silod. The connection uses SideBack's own protocol over TLS.")
                }

                Section {
                    SecureField("Token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save token") {
                        KeychainStore.savePassword(token, for: store.destination.id)
                        token = ""
                        failure = nil
                    }
                    .disabled(token.isEmpty)
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("The contents of the file passed to --token-file. Stored only in this device's Keychain.")
                }

                Section {
                    Button {
                        runTest()
                    } label: {
                        if isTesting {
                            HStack {
                                ProgressView()
                                Text("Testing…")
                            }
                        } else {
                            Label("Test connection", systemImage: "bolt.horizontal")
                        }
                    }
                    .disabled(isTesting || !store.destination.isValid || !hasToken)

                    if let report {
                        ForEach(report.steps, id: \.self) { step in
                            Label(step, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.footnote)
                        }
                    }

                    if let failure {
                        Label(failure, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                } header: {
                    Text("Test")
                } footer: {
                    Text("Writes a small test file and immediately deletes it. No device data is transferred.")
                }

                if let fingerprint = store.destination.pinnedFingerprint {
                    Section {
                        Text(fingerprint)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Button("Forget certificate", role: .destructive) {
                            store.destination.pinnedFingerprint = nil
                            report = nil
                        }
                    } header: {
                        Text("Pinned certificate")
                    } footer: {
                        Text("Compare against the fingerprint silod prints on startup. If it ever changes, SideBack will refuse to connect.")
                    }
                }
            }
            .navigationTitle("Backup Server")
        }
    }

    private func runTest() {
        guard let storedToken = KeychainStore.password(for: store.destination.id) ?? (token.isEmpty ? nil : token) else {
            failure = "Save a token first."
            return
        }

        isTesting = true
        report = nil
        failure = nil
        let destination = store.destination

        Task {
            do {
                let result = try await SilodHealthCheck.run(destination: destination, token: storedToken)
                await MainActor.run {
                    report = result
                    // Trust on first use: remember what answered, so a
                    // different certificate later is treated as an error.
                    if store.destination.pinnedFingerprint == nil {
                        store.destination.pinnedFingerprint = result.fingerprint
                    }
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    failure = error.localizedDescription
                    isTesting = false
                }
            }
        }
    }
}

#Preview {
    DestinationView()
}
