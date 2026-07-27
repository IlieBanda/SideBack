import SwiftUI

struct AboutView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "externaldrive.badge.icloud")
                            .font(.system(size: 34))
                            .foregroundStyle(.blue)
                            .symbolRenderingMode(.hierarchical)
                        Text("SideBack")
                            .font(.title2.bold())
                        Text("A full iPhone backup straight to your own server — no Mac, no iCloud, no separate box. The same protocol Finder uses, just with the phone talking to itself.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }

                Section("How it works") {
                    aboutRow(
                        icon: "network",
                        title: "Tunnel",
                        detail: "LocalDevVPN/StosVPN opens a loopback to the phone itself; then RPPairing → CoreDeviceProxy → RSD — the same handshake Xcode uses for wireless debugging."
                    )
                    aboutRow(
                        icon: "shippingbox",
                        title: "mobilebackup2",
                        detail: "The protocol client (idevice, Rust) talks to BackupAgent2 directly — the same protocol Finder uses for a full USB/Wi-Fi backup."
                    )
                    aboutRow(
                        icon: "externaldrive.connected.to.line.below",
                        title: "silod",
                        detail: "Files go to your server over a custom protocol on top of TLS: resumable, with a SHA-256 check on every file before it's published."
                    )
                }

                Section {
                    ForEach(statusItems) { item in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                if let detail = item.detail {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: item.state.symbol)
                                .foregroundStyle(item.state.tint)
                        }
                    }
                } header: {
                    Text("Status")
                } footer: {
                    Text("Updated as real-device testing happens, not on a schedule.")
                }

                Section {
                    Text("Built for testing on your own devices. Restore is only ever tested on a separate device, never your primary one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Important")
                }
            }
            .navigationTitle("About SideBack")
        }
    }

    private func aboutRow(icon: String, title: String, detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .symbolRenderingMode(.hierarchical)
        }
        .padding(.vertical, 2)
    }

    private enum StatusState {
        case done, partial, pending

        var symbol: String {
            switch self {
            case .done: return "checkmark.circle.fill"
            case .partial: return "circle.lefthalf.filled"
            case .pending: return "circle.dotted"
            }
        }

        var tint: Color {
            switch self {
            case .done: return .green
            case .partial: return .orange
            case .pending: return .secondary
            }
        }
    }

    private struct StatusItem: Identifiable {
        let id = UUID()
        let title: String
        let detail: String?
        let state: StatusState
    }

    private let statusItems: [StatusItem] = [
        StatusItem(title: "Tunnel and mobilebackup2", detail: "Connection and version exchange confirmed on real hardware.", state: .done),
        StatusItem(title: "Transfer with integrity checking", detail: "Every file is checked against SHA-256 before being published on the server.", state: .done),
        StatusItem(title: "Safe cancellation", detail: "An interrupted file stays a draft instead of corrupting what's already saved.", state: .done),
        StatusItem(title: "Backup encryption", detail: "On by default, with a real device round-trip proving password possession before a run starts.", state: .done),
        StatusItem(title: "File-level resume", detail: "A file already fully saved on the server is recognized and not re-sent after an interruption.", state: .partial),
        StatusItem(title: "First full backup to completion", detail: "Needed before restore can be verified at all.", state: .partial),
        StatusItem(title: "Restore", detail: "Planned, tested only on a separate test device.", state: .pending),
    ]
}

#Preview {
    AboutView()
}
