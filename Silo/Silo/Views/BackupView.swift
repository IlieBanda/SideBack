import SwiftUI
import LocalAuthentication
import UIKit

/// Runs and monitors an actual backup. Nothing here fires without an
/// explicit tap through the confirmation dialog below — starting this
/// starts a real, full `mobilebackup2` backup of the device, streamed to
/// whatever server is configured under "Server".
struct BackupView: View {
    @StateObject private var controller = BackupController()
    @StateObject private var destinationStore = DestinationStore()
    @State private var tunnel: TunnelDetector.Tunnel?
    @State private var isConfirming = false
    /// Refreshed on the tick below while a run is in flight, so the live
    /// protocol log stays current without the controller having to publish
    /// it. Only read while the group is actually open — a running backup
    /// appends to the log continuously, and re-reading it every tick to
    /// render into a collapsed view is pure jank.
    @State private var liveLog = ""
    @State private var isLiveLogOpen = false
    /// Captured once on appear: what the launch before this one logged.
    /// After a crash this is the only surviving record of how far the run
    /// got, since the relaunch truncates the live log.
    @State private var previousRunLog = ""
    @State private var syncLockEnabled = SyncLock.isEnabled
    @State private var jktcpWindowScaleBits = DeviceTunnel.jktcpWindowScaleBits
    @State private var storageEstimateBytes: UInt64?
    @State private var storageEstimateError: String?
    @State private var isEstimatingStorage = false
    @State private var encryptionEnabled = BackupEncryptionStore.isEnabled
    @State private var hasStoredPassword = BackupEncryptionStore.password != nil
    @State private var isConfirmedOnDevice = BackupEncryptionStore.isConfirmedSetOnDevice
    @State private var passwordField = ""
    @State private var passwordConfirmField = ""
    @State private var passwordSaveError: String?
    @State private var showEscrowSheet = false
    @State private var escrowRetypeField = ""
    /// nil = not checked yet. Only meaningful once `hasStoredPassword` is
    /// true or the user is about to type an existing password — see
    /// `BackupPasswordVerifier` for why this can't just be assumed.
    @State private var deviceWillEncrypt: Bool?
    @State private var isCheckingWillEncrypt = false
    @State private var existingPasswordField = ""
    @State private var isVerifyingPassword = false
    @State private var verifyError: String?
    @State private var stuckTemporaryPassword: String?
    @State private var revealedPassword: String?

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                statusSection
                encryptionSection
                diagnosticsSection
                experimentsSection
                backgroundSection
                controlsSection
            }
            .navigationTitle("Backup")
            .onAppear {
                tunnel = TunnelDetector.activeTunnel()
                previousRunLog = DebugLog.previousRun()
                checkWillEncryptIfNeeded()
            }
            .onReceive(timer) { _ in
                if controller.isRunning {
                    if isLiveLogOpen { liveLog = controller.liveDebugTail }
                } else {
                    tunnel = TunnelDetector.activeTunnel()
                    isConfirmedOnDevice = BackupEncryptionStore.isConfirmedSetOnDevice
                    checkWillEncryptIfNeeded()
                }
            }
            .confirmationDialog(
                "Start a real backup?",
                isPresented: $isConfirming,
                titleVisibility: .visible
            ) {
                Button("Start", role: .destructive) { start() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(startConfirmationMessage)
            }
            .sheet(isPresented: $showEscrowSheet) {
                escrowSheet
            }
            .sheet(isPresented: Binding(
                get: { revealedPassword != nil },
                set: { if !$0 { revealedPassword = nil } }
            )) {
                NavigationStack {
                    List {
                        Section {
                            Text(revealedPassword ?? "")
                                .font(.title3.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 8)
                        } footer: {
                            Text("Confirmed with this phone's Face ID/passcode before showing.")
                        }
                    }
                    .navigationTitle("Backup Password")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { revealedPassword = nil }
                        }
                    }
                }
            }
        }
    }

    /// Forces a deliberate, out-of-band copy of the password before it's
    /// ever saved. This password lives in the Keychain of the very phone
    /// the backup protects — "phone is lost/broken" means "backup is
    /// permanently unreadable" unless the user wrote this down somewhere
    /// else first. A checkbox is too easy to click through; retyping the
    /// password they just saw is a real (if small) proof they looked at it.
    private var escrowSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text(passwordField)
                        .font(.title3.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } header: {
                    Text("Backup Password")
                } footer: {
                    Text("Save it right now in a password manager or another safe place — not on this phone.")
                }

                Section {
                    Text("This password can't be reset normally. Starting with iOS 11, the only way to remove a backup password is \"Reset All Settings\" (Settings → General → Transfer or Reset iPhone → Reset → Reset All Settings). That wipes Wi-Fi passwords, display and sound settings, Apple Pay cards — and makes every earlier encrypted backup of this phone PERMANENTLY UNREADABLE, including ones already sent to this server.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Section {
                    TextField("Type the password again to confirm you saved it", text: $escrowRetypeField)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("This isn't a typo check — it's confirmation that you actually copied the password from here, not just read the warning.")
                }
            }
            .navigationTitle("Save the Password")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showEscrowSheet = false
                        escrowRetypeField = ""
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { confirmEscrowAndSave() }
                        .disabled(escrowRetypeField != passwordField)
                }
            }
        }
    }

    private var startConfirmationMessage: String {
        let base = "SideBack will read data from the phone over mobilebackup2 and send it to \(destinationStore.destination.host):\(String(destinationStore.destination.port)). This is a real operation, not a test. The phone may show a system prompt to enter your passcode to trust this new backup client — that's from iOS, not SideBack; enter it on the phone itself."
        let encryptionNote = BackupEncryptionStore.isEnabled
            ? " The backup will be encrypted with the password set below."
            : " Encryption is currently off — Keychain, passwords, Health, and call history won't be in the backup."
        return base + encryptionNote
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            switch controller.phase {
            case .idle:
                ContentUnavailableView {
                    Label("No backup running", systemImage: "arrow.triangle.2.circlepath.circle")
                } description: {
                    Text("Set up a server in the \"Server\" tab, then tap \"Start Backup\" below.")
                }
                .listRowInsets(EdgeInsets())
                storageEstimateRow

            case .connecting:
                HStack {
                    ProgressView()
                    Text("Connecting…")
                }
                liveLogGroup

            case .running(let sent, let batchTotal, let overall):
                VStack(alignment: .leading, spacing: 8) {
                    Label("Backup in progress", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.blue)
                    // The device's own estimate isn't strictly bounded to
                    // [0, 1] — the reference idevicebackup2 clamps it for
                    // display too (idevicebackup2.c: `if (overall_progress
                    // >= 100.0F) ...`). It's a rough internal estimate, not
                    // a byte-accurate fraction; showing 101% would just be
                    // confusing, not more honest.
                    let clampedOverall = min(max(overall, 0), 1)
                    ProgressView(value: clampedOverall)
                    Text(verbatim: "Overall progress: \(Int(clampedOverall * 100))% — the phone's own estimate")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(verbatim: "Sent to server: \(formatBytes(sent))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let lock = controller.syncLockStatus {
                        Text(lock)
                            .font(.footnote)
                            .foregroundStyle(controller.syncLockStatus?.contains("NOT held") == true ? .orange : .secondary)
                    }
                    if batchTotal > 0 {
                        Text(verbatim: "Current file batch: \(formatBytes(batchTotal))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let encryptionStatus = controller.encryptionStatus {
                        Text(encryptionStatus)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                liveLogGroup

            case .cancelling:
                HStack {
                    ProgressView()
                    Text("Cancelling…")
                }
                liveLogGroup

            case .completed:
                Label("Backup complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

            case .cancelled(let activity, let debugLog, let abandoned):
                Label("Cancelled", systemImage: "stop.circle.fill")
                    .foregroundStyle(.orange)
                Text("The file that was transferring when cancelled stayed incomplete on the server — it's not treated as whole and it's not lost: the next run will resend exactly that file instead of starting over.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if abandoned {
                    Text("The cancellation had to be forced: the mobilebackup2 session was waiting on a response from the phone at that moment and never reacted on its own. The log below shows exactly what it was stuck on.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                activityGroup(activity)
                logGroup(debugLog, title: "idevice protocol (detailed log for this attempt)")

            case .failed(let message, let activity, let debugLog):
                Label("Error", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                activityGroup(activity)
                logGroup(debugLog, title: "idevice protocol (detailed log for this attempt)")
            }
        } header: {
            Text("Status")
        }
    }

    /// `mobilebackup2` has no way to report the real backup size ahead of
    /// time — confirmed against libimobiledevice's own maintainers
    /// (github.com/libimobiledevice/libimobiledevice#353). Used storage is
    /// the closest available proxy: usually a bit more than the real backup
    /// (some caches/system data are excluded), never less.
    @ViewBuilder
    private var storageEstimateRow: some View {
        if let storageEstimateBytes {
            Text(verbatim: "~\(formatBytes(storageEstimateBytes)) used on the phone — the backup weighs no more than that, usually a bit less.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if let storageEstimateError {
            Text("Couldn't estimate the size: \(storageEstimateError)")
                .font(.footnote)
                .foregroundStyle(.orange)
        } else {
            Button {
                estimateStorage()
            } label: {
                if isEstimatingStorage {
                    HStack {
                        ProgressView()
                        Text("Estimating size…")
                    }
                } else {
                    Label("Estimate backup size", systemImage: "internaldrive")
                }
            }
            .disabled(isEstimatingStorage || blockingReason() != nil)
            .font(.footnote)
        }
    }

    /// The protocol log as it stands right now, available mid-run so a
    /// slow attempt can be diagnosed where it is rather than only after it
    /// fails — a run that hangs may never produce a failure screen at all.
    private var liveLogGroup: some View {
        DisclosureGroup("idevice protocol (live)", isExpanded: $isLiveLogOpen) {
            if liveLog.isEmpty {
                Text("Empty so far — refreshes every couple of seconds.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                logBody(liveLog)
            }
        }
        .onChange(of: isLiveLogOpen) { _, open in
            if open { liveLog = controller.liveDebugTail }
        }
    }

    @ViewBuilder
    private func activityGroup(_ activity: [String]) -> some View {
        if !activity.isEmpty {
            DisclosureGroup("What managed to happen (\(activity.count))") {
                ForEach(Array(activity.enumerated()), id: \.offset) { _, entry in
                    Text(entry)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text("Not a single file request reached the server — everything broke off during idevice's own handshake with the phone, before our files.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func logGroup(_ log: String, title: String) -> some View {
        if !log.isEmpty {
            DisclosureGroup(title) { logBody(log) }
        }
    }

    /// Renders only the end of `log`: SwiftUI lays a `Text` out in one go on
    /// the main thread, so handing it a whole backup's worth of protocol
    /// tracing locks the app up. Copying still takes everything.
    private func logBody(_ log: String) -> some View {
        let shown = log.count > 8_000 ? "…(showing only the end)\n" + String(log.suffix(8_000)) : log
        return VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(shown)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
            Button("Copy Log") {
                UIPasteboard.general.string = log
            }
            .font(.footnote)
        }
    }

    private var diagnosticsSection: some View {
        Section {
            if previousRunLog.isEmpty {
                Text("Empty — the previous run didn't log anything.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                logGroup(previousRunLog, title: "Previous run's log")
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("If the app crashed, a record of the previous run stays here — the last line shows exactly what step it broke off on. The live log resets on relaunch, so this is where to look after a crash.")
        }
    }

    /// Backup encryption is a *device* setting, not a per-run flag: once
    /// `mobilebackup2_change_password` succeeds, every future backup — from
    /// Silo, from Finder, from anyone who plugs the phone in — is encrypted
    /// with this password until it's changed again. Without it, Keychain
    /// items, Health data, call history, and Safari history are silently
    /// left out of an otherwise "successful" backup.
    private var encryptionSection: some View {
        Section {
            Toggle("Encrypt backup", isOn: $encryptionEnabled)
                .disabled(controller.isRunning)
                .onChange(of: encryptionEnabled) { _, on in BackupEncryptionStore.isEnabled = on }

            if encryptionEnabled {
                if let stuckTemporaryPassword {
                    // The worst case: a verification attempt swapped the
                    // device to a throwaway password and couldn't swap it
                    // back. This IS the device's real password right now.
                    Label("Password not restored automatically!", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(stuckTemporaryPassword)
                        .font(.title3.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text("This is a temporary password that's actually set on the device right now. Write it down immediately, then try confirming again so SideBack can restore your regular password.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if isConfirmedOnDevice {
                    Label("Password confirmed on device", systemImage: "checkmark.seal.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                    Button("Show Password") { revealPassword() }
                        .disabled(controller.isRunning)
                    Button("Change Password", role: .destructive) { startPasswordChange() }
                        .disabled(controller.isRunning)
                } else if hasStoredPassword, deviceWillEncrypt == true {
                    Label("Device is already encrypted — confirm the saved password", systemImage: "questionmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Button("Confirm Saved Password") { verifyStoredPassword() }
                        .disabled(controller.isRunning || isVerifyingPassword)
                    Button("Enter a Different Password", role: .destructive) { startPasswordChange() }
                        .disabled(controller.isRunning || isVerifyingPassword)
                    if isVerifyingPassword {
                        HStack { ProgressView(); Text("Verifying…") }.font(.footnote)
                    }
                    if let verifyError {
                        Text(verifyError).font(.footnote).foregroundStyle(.orange)
                    }
                } else if hasStoredPassword {
                    Label(
                        isCheckingWillEncrypt ? "Checking device state…" : "Password saved, will be set on the device on the next run",
                        systemImage: isCheckingWillEncrypt ? "hourglass" : "clock.badge.exclamationmark"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    Button("Change Password", role: .destructive) { startPasswordChange() }
                        .disabled(controller.isRunning)
                } else if deviceWillEncrypt == true {
                    Text("The device reports that backup encryption is already on. Enter the password that's actually set on the phone right now (e.g. one set at some point in Finder/iTunes) — SideBack will verify it with a real round-trip to the device; nothing is lost if it turns out to be wrong.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    SecureField("Device's current password", text: $existingPasswordField)
                        .disabled(controller.isRunning || isVerifyingPassword)
                    Button("Verify") { verifyExistingPassword() }
                        .disabled(controller.isRunning || isVerifyingPassword || existingPasswordField.isEmpty)
                    if isVerifyingPassword {
                        HStack { ProgressView(); Text("Verifying…") }.font(.footnote)
                    }
                    if let verifyError {
                        Text(verifyError).font(.footnote).foregroundStyle(.orange)
                    }
                } else {
                    SecureField("Backup password", text: $passwordField)
                        .disabled(controller.isRunning)
                    SecureField("Repeat password", text: $passwordConfirmField)
                        .disabled(controller.isRunning)
                    Button("Next") { proceedToEscrow() }
                        .disabled(controller.isRunning || passwordField.isEmpty)
                    if let passwordSaveError {
                        Text(passwordSaveError)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
        } header: {
            Text("Encryption")
        } footer: {
            Text(encryptionEnabled
                ? "Without a password, iOS excludes Keychain (saved passwords), Health data, call history, and Safari history from the backup — even though the run itself reports success. The password is stored only in this device's Keychain and is needed to restore the backup later."
                : "A backup without encryption isn't recommended: some data (passwords, Health, calls, Safari) won't be in it. Turn it off deliberately, not by default.")
        }
    }

    private var experimentsSection: some View {
        Section {
            Toggle("Take the sync lock", isOn: $syncLockEnabled)
                .disabled(controller.isRunning)
                .onChange(of: syncLockEnabled) { _, on in SyncLock.isEnabled = on }

            Stepper(
                "Receive window: scale \(jktcpWindowScaleBits) (≈\(formatBytes(windowBytes(for: jktcpWindowScaleBits))))",
                value: $jktcpWindowScaleBits, in: 0...14
            )
            .disabled(controller.isRunning)
            .onChange(of: jktcpWindowScaleBits) { _, value in DeviceTunnel.jktcpWindowScaleBits = value }
        } header: {
            Text("Experiments")
        } footer: {
            Text("Sync lock: this is what desktop idevicebackup2 does — before a backup it takes an iTunes lock file on the device so the phone doesn't do its own syncing work in parallel with ours. Measurements showed the phone sends nothing for 88% of a backup's wall-clock time. Unverified, off by default.\n\nReceive window: scale 2 (~256 KB) is a conservative value that bounds how much data is lost to a single dropped packet. Scale/RTT = the throughput ceiling — if the tunnel's real RTT is small, the scale can go higher without risking long stalls on packet loss; check the rtt= values in the protocol log before changing this.")
        }
    }

    private func windowBytes(for scaleBits: Int) -> UInt64 {
        UInt64(65534) << UInt64(scaleBits)
    }

    private var backgroundSection: some View {
        Section {
            Toggle("Keep working with the screen off", isOn: $controller.keepAliveInBackground)
                .disabled(controller.isRunning)
                .onChange(of: controller.keepAliveInBackground) { _, on in
                    if on { BackgroundKeepAlive.shared.requestAuthorization() }
                }
            if controller.keepAliveInBackground, !BackgroundKeepAlive.shared.isAuthorized {
                Text("\"Always\" location access is needed — without it, iOS will suspend SideBack along with the backup. Grant it in the system prompt or in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Background")
        } footer: {
            Text("The backup lives inside SideBack: the moment iOS suspends the app, the connection to the phone breaks mid-transfer. There's no honest way to run for hours in the background on iOS, so this uses a workaround instead — SideBack keeps the coarsest possible background location updates going, and the system doesn't suspend it as a result. The coordinates themselves are never read or sent anywhere, only the fact that updates are happening matters. Cost: noticeable battery drain and a location indicator in the status bar. If you leave this running overnight, keep it plugged in.")
        }
    }

    private var controlsSection: some View {
        Section {
            if controller.isRunning {
                Button("Cancel", role: .destructive) {
                    controller.cancel()
                }
                .disabled({ if case .cancelling = controller.phase { return true } else { return false } }())
            } else {
                Button {
                    isConfirming = true
                } label: {
                    Label("Start Backup", systemImage: "play.fill")
                }
                .disabled(blockingReason() != nil)

                if let reason = blockingReason() {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        } footer: {
            Text("Cancelling is safe at any point: an unfinished file on the server isn't published until its hash matches, so an interrupted transfer never corrupts what's already saved.")
        }
    }

    // MARK: - Actions

    private func blockingReason() -> String? {
        guard let tunnel, tunnel.gatewayAddress != nil else { return "An active LocalDevVPN is needed." }
        guard PairingFileStore.isPresent else { return "A pairing file is needed (\"Status\" tab)." }
        guard destinationStore.destination.isValid else { return "Set up a server (\"Server\" tab)." }
        guard KeychainStore.password(for: destinationStore.destination.id) != nil else { return "Save the server token (\"Server\" tab)." }
        if BackupEncryptionStore.isEnabled, !BackupEncryptionStore.isConfirmedSetOnDevice {
            if BackupEncryptionStore.password == nil {
                return "Set a backup encryption password above, or turn encryption off."
            }
            return "Confirm the encryption password above, or turn encryption off."
        }
        return nil
    }

    private func start() {
        guard let tunnel, let gateway = tunnel.gatewayAddress,
              let pairingData = PairingFileStore.load(),
              let token = KeychainStore.password(for: destinationStore.destination.id)
        else { return }
        liveLog = ""
        controller.start(gatewayAddress: gateway, pairingFileData: pairingData, destination: destinationStore.destination, token: token)
    }

    private func checkWillEncryptIfNeeded() {
        guard encryptionEnabled, !isConfirmedOnDevice, deviceWillEncrypt == nil, !isCheckingWillEncrypt,
              let tunnel, let gateway = tunnel.gatewayAddress, let pairingData = PairingFileStore.load()
        else { return }
        isCheckingWillEncrypt = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = DeviceTunnel.checkWillEncrypt(gatewayAddress: gateway, pairingFileData: pairingData)
            DispatchQueue.main.async {
                isCheckingWillEncrypt = false
                if case .success(let value) = result { deviceWillEncrypt = value }
            }
        }
    }

    private func startPasswordChange() {
        passwordField = ""
        passwordConfirmField = ""
        existingPasswordField = ""
        verifyError = nil
        hasStoredPassword = false
        isConfirmedOnDevice = false
        BackupEncryptionStore.deletePassword()
        deviceWillEncrypt = nil
    }

    private func verifyStoredPassword() {
        guard let password = BackupEncryptionStore.password else { return }
        runVerification(candidate: password, isNewPassword: false)
    }

    private func verifyExistingPassword() {
        runVerification(candidate: existingPasswordField, isNewPassword: true)
    }

    /// `isNewPassword` only controls whether it's saved to Keychain on
    /// success — `verifyStoredPassword` already has it saved, this just
    /// confirms it's correct.
    private func runVerification(candidate: String, isNewPassword: Bool) {
        guard let tunnel, let gateway = tunnel.gatewayAddress,
              let pairingData = PairingFileStore.load(),
              let token = KeychainStore.password(for: destinationStore.destination.id)
        else { return }
        verifyError = nil
        isVerifyingPassword = true
        Task {
            let outcome = await BackupPasswordVerifier.verify(
                gatewayAddress: gateway, pairingFileData: pairingData,
                destination: destinationStore.destination, token: token, candidate: candidate
            )
            await MainActor.run {
                isVerifyingPassword = false
                switch outcome {
                case .correct:
                    if isNewPassword { BackupEncryptionStore.savePassword(candidate) }
                    BackupEncryptionStore.isConfirmedSetOnDevice = true
                    hasStoredPassword = true
                    isConfirmedOnDevice = true
                    existingPasswordField = ""
                case .incorrect(let message):
                    verifyError = "Wrong password: \(message)"
                case .error(let message):
                    verifyError = "Couldn't verify: \(message)"
                case .stuckOnTemporaryPassword(let temporary):
                    stuckTemporaryPassword = temporary
                }
            }
        }
    }

    private func revealPassword() {
        guard let password = BackupEncryptionStore.password else { return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            verifyError = "Face ID/passcode isn't set up on this device — the password can't be shown."
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Show the backup password") { success, _ in
            DispatchQueue.main.async {
                if success { revealedPassword = password }
            }
        }
    }

    private func proceedToEscrow() {
        passwordSaveError = nil
        guard passwordField == passwordConfirmField else {
            passwordSaveError = "Passwords don't match."
            return
        }
        guard passwordField.count >= 4 else {
            passwordSaveError = "Password too short."
            return
        }
        escrowRetypeField = ""
        showEscrowSheet = true
    }

    private func confirmEscrowAndSave() {
        guard escrowRetypeField == passwordField else { return }
        BackupEncryptionStore.savePassword(passwordField)
        hasStoredPassword = true
        isConfirmedOnDevice = false
        passwordField = ""
        passwordConfirmField = ""
        escrowRetypeField = ""
        showEscrowSheet = false
    }

    private func estimateStorage() {
        guard let tunnel, let gateway = tunnel.gatewayAddress, let pairingData = PairingFileStore.load() else { return }
        isEstimatingStorage = true
        storageEstimateError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = DeviceTunnel.estimateUsedStorage(gatewayAddress: gateway, pairingFileData: pairingData)
            DispatchQueue.main.async {
                isEstimatingStorage = false
                switch result {
                case .success(let bytes): storageEstimateBytes = bytes
                case .failure(let message): storageEstimateError = message
                }
            }
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

#Preview {
    BackupView()
}
