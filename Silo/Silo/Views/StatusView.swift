import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Live status of the on-device pieces Silo depends on. Everything here is
/// real: the VPN check is a `getifaddrs` scan, and the tunnel section runs
/// an actual authenticated RPPairing/RSD session against the device.
struct StatusView: View {
    @State private var tunnel: TunnelDetector.Tunnel?
    @State private var snapshot: TunnelSnapshot?
    @State private var tunnelError: String?
    @State private var isInspecting = false
    @State private var hasPairingFile = PairingFileStore.isPresent
    @State private var isImportingPairingFile = false
    @State private var importError: String?
    @State private var pairingFileDiagnostics: String?

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                tunnelSection
                pairingSection
                inspectSection

                if let snapshot {
                    backupServiceSection(snapshot)
                    servicesSection(snapshot)
                }
            }
            .navigationTitle("SideBack")
            .onAppear {
                refresh()
                if pairingFileDiagnostics == nil, let existing = PairingFileStore.load() {
                    pairingFileDiagnostics = Self.describeTopLevelKeys(of: existing)
                }
            }
            .onReceive(timer) { _ in refresh() }
            .fileImporter(
                isPresented: $isImportingPairingFile,
                allowedContentTypes: [.item],
                onCompletion: handleImport
            )
        }
    }

    // MARK: - Sections

    private var tunnelSection: some View {
        Section {
            if let tunnel {
                Label("LocalDevVPN connected", systemImage: "network")
                    .foregroundStyle(.green)
                LabeledContent("Interface", value: tunnel.interfaceName)
                LabeledContent("Device address", value: tunnel.address)
                if let gateway = tunnel.gatewayAddress {
                    LabeledContent("Tunnel gateway", value: gateway)
                }
            } else {
                ContentUnavailableView {
                    Label("LocalDevVPN not detected", systemImage: "network.slash")
                } description: {
                    Text("SideBack doesn't run its own VPN tunnel — it connects to an already-installed LocalDevVPN/StosVPN.")
                }
                .listRowInsets(EdgeInsets())
            }
        }
    }

    private var pairingSection: some View {
        Section {
            if hasPairingFile {
                Label("Pairing file saved", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                if let diagnostics = pairingFileDiagnostics {
                    Text(diagnostics)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Replace") { isImportingPairingFile = true }
                Button("Delete", role: .destructive) {
                    PairingFileStore.clear()
                    hasPairingFile = false
                    snapshot = nil
                    tunnelError = nil
                    pairingFileDiagnostics = nil
                }
            } else {
                Button {
                    isImportingPairingFile = true
                } label: {
                    Label("Import pairing file", systemImage: "square.and.arrow.down")
                }
                Button {
                    pasteFromClipboard()
                } label: {
                    Label("Paste from clipboard", systemImage: "doc.on.clipboard")
                }
            }
            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
        } header: {
            Text("Pairing file")
        } footer: {
            Text("RpPairing format (identifier / private_key / public_key). Stored only in this device's Keychain.")
        }
    }

    private var inspectSection: some View {
        Section {
            if let tunnel, tunnel.gatewayAddress != nil, hasPairingFile {
                Button {
                    runInspection(tunnel: tunnel)
                } label: {
                    if isInspecting {
                        HStack {
                            ProgressView()
                            Text("Connecting to device…")
                        }
                    } else {
                        Label("Scan device", systemImage: "bolt.horizontal")
                    }
                }
                .disabled(isInspecting)
            } else {
                Text(hasPairingFile ? "An active LocalDevVPN is needed." : "A pairing file is needed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let snapshot {
                Label("Tunnel established", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                LabeledContent("Device UUID", value: snapshot.deviceUUID)
                    .font(.caption.monospaced())
                if snapshot.protocolVersion >= 0 {
                    LabeledContent("RSD protocol version", value: "\(snapshot.protocolVersion)")
                }
                LabeledContent("Services found", value: "\(snapshot.services.count)")
            }

            if let tunnelError {
                Label("Failed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(tunnelError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Tunnel")
        } footer: {
            Text("TCP :49152 → RPPairing → CoreDeviceProxy → RSD. Scanning only reads the service list — no data is copied from the device.")
        }
    }

    private func backupServiceSection(_ snapshot: TunnelSnapshot) -> some View {
        Section {
            switch snapshot.backupServiceStatus {
            case .connected:
                Label("mobilebackup2 reachable and open", systemImage: "externaldrive.badge.checkmark")
                    .foregroundStyle(.green)
                Text("SideBack successfully opened a channel to the backup service directly on the phone. This is the exact service iTunes/Finder use for a full backup. No backup was started.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label("mobilebackup2 found, but didn't open", systemImage: "externaldrive.badge.xmark")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .none:
                Label("mobilebackup2 not advertised over RSD", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
                Text("The service wasn't found in the list — it may only be reachable over the classic lockdownd path.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Backup service")
        }
    }

    private func servicesSection(_ snapshot: TunnelSnapshot) -> some View {
        Section {
            ForEach(snapshot.services) { service in
                VStack(alignment: .leading, spacing: 4) {
                    Text(service.name)
                        .font(.callout)
                        .fontWeight(service.isMobileBackup2 ? .bold : .regular)
                        .foregroundStyle(service.isMobileBackup2 ? Color.green : Color.primary)
                    HStack(spacing: 8) {
                        // String(...) avoids SwiftUI's localized number
                        // formatting, which renders port 51345 as "51,345".
                        Text(verbatim: "port \(String(service.port))")
                        if service.usesRemoteXPC {
                            Text("XPC")
                        }
                        if let version = service.serviceVersion {
                            Text(verbatim: "v\(String(version))")
                        }
                    }
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Device services (\(snapshot.services.count))")
        } footer: {
            Text("The full list of what the device advertises over the RSD tunnel.")
        }
    }

    // MARK: - Actions

    private func refresh() {
        tunnel = TunnelDetector.activeTunnel()
    }

    private func runInspection(tunnel: TunnelDetector.Tunnel) {
        guard let gateway = tunnel.gatewayAddress, let pairingData = PairingFileStore.load() else { return }
        isInspecting = true
        tunnelError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = DeviceTunnel.inspect(gatewayAddress: gateway, pairingFileData: pairingData)
            DispatchQueue.main.async {
                switch result {
                case .success(let value):
                    snapshot = value
                    tunnelError = nil
                case .failure(let message):
                    snapshot = nil
                    tunnelError = message
                }
                isInspecting = false
            }
        }
    }

    private func handleImport(_ result: Swift.Result<URL, Error>) {
        importError = nil
        switch result {
        case .failure(let error):
            importError = "Import failed: \(error.localizedDescription)"
        case .success(let url):
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                store(pairingData: data)
            } catch {
                importError = "Couldn't read the file: \(error.localizedDescription)"
            }
        }
    }

    /// Alternate import path, in case the system file picker misbehaves for
    /// a given file (observed on this iOS 27 beta: some local .plist files
    /// are unresponsive to tap in the picker).
    private func pasteFromClipboard() {
        importError = nil
        let pasteboard = UIPasteboard.general

        if let data = pasteboard.data(forPasteboardType: UTType.propertyList.identifier)
            ?? pasteboard.data(forPasteboardType: UTType.xml.identifier)
            ?? pasteboard.data(forPasteboardType: UTType.data.identifier)
            ?? pasteboard.data(forPasteboardType: "public.data") {
            store(pairingData: data)
            return
        }

        if let string = pasteboard.string, let data = string.data(using: .utf8) {
            store(pairingData: data)
            return
        }

        importError = "No data on the clipboard. In Files, press and hold the file, then \"Copy\"."
    }

    private func store(pairingData data: Data) {
        PairingFileStore.save(data)
        hasPairingFile = true
        snapshot = nil
        tunnelError = nil
        pairingFileDiagnostics = Self.describeTopLevelKeys(of: data)
    }

    /// Diagnostic only: reports the *shape* of the imported plist (top-level
    /// keys) without ever printing the actual secret values.
    private static func describeTopLevelKeys(of data: Data) -> String {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return "Not recognizable as a plist (\(data.count) bytes)."
        }
        guard let dict = plist as? [String: Any] else {
            return "A plist, but not a top-level dictionary (\(type(of: plist)))."
        }
        return "Keys: \(dict.keys.sorted().joined(separator: ", "))"
    }
}

#Preview {
    StatusView()
}
