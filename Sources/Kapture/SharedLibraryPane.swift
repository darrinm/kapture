// Settings › Shared Library (docs/SHARED-LIBRARY.md §10.4, and stage 1 of the rollout).
//
// Everything behind this pane was built and tested before any of it could be reached: nothing
// called `enrol`, `createKey` or `adoptKey`, so the toggle could only ever move the library into
// `.locked`. This is the path from off to two Macs sharing a library.
//
// Two rules the copy here has to carry, because nothing else can:
//   F16 — losing the key makes the library unreadable to everyone, the operator included, so the
//         recovery code is shown before the first upload and confirmed in writing.
//   F86 — *locked* and *empty* must never look alike. Someone who fears they have lost a year of
//         captures needs to be told which one this is.

import SwiftUI
import AppKit
import KaptureCore
import KaptureSync

@MainActor
final class SharedLibraryModel: ObservableObject {
    @Published var state: LibraryState = .disabled
    @Published var devices: [DeviceInfo] = []
    @Published var busy = false
    @Published var error: String?
    /// Shown once, at creation, and re-displayable afterwards on a Mac that holds the key.
    @Published var recoveryCode: String?
    @Published var fingerprint: String?

    var hasKey: Bool { LibraryService.hasKey }
    var isEnrolled: Bool { LibraryService.isEnrolled }

    func refresh() async {
        state = await LibraryService.shared.state
        guard state == .ready else { return }
        devices = (try? await LibraryService.shared.devices()) ?? []
    }

    /// Create the library here and enrol this Mac as its first device.
    func create(ownerToken: String, deviceName: String) async {
        await run {
            let (result, code) = try await LibraryService.createLibrary(
                ownerToken: ownerToken, deviceName: deviceName)
            self.recoveryCode = code
            self.fingerprint = result.fingerprint
        }
    }

    /// Join a library this Mac already has the key for, or is about to be given it for.
    func join(ownerToken: String, deviceName: String) async {
        await run {
            let result = try await LibraryService.enrol(ownerToken: ownerToken,
                                                        deviceName: deviceName)
            self.fingerprint = result.fingerprint
        }
    }

    func adopt(recoveryCode code: String) async {
        await run { try LibraryService.adoptKey(fromRecoveryCode: code) }
    }

    func revealRecoveryCode() {
        recoveryCode = LibraryService.recoveryCode()
    }

    func approve(_ device: DeviceInfo) async {
        await run { try await LibraryService.shared.approve(deviceID: device.deviceID) }
    }

    func revoke(_ device: DeviceInfo) async {
        await run { try await LibraryService.shared.revoke(deviceID: device.deviceID) }
    }

    /// Start or restart the service after anything that changes what this Mac holds.
    func restart() async {
        guard let library = CaptureCoordinator.shared.library else { return }
        _ = await LibraryService.shared.start(db: library.db,
                                              deviceID: LibraryDeviceID.current())
        await refresh()
    }

    private func run(_ body: @escaping () async throws -> Void) async {
        busy = true
        error = nil
        do {
            try await body()
            await restart()
        } catch let failure as SyncFailure {
            error = failure.description
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }
}

struct SharedLibraryPane: View {
    @StateObject private var model = SharedLibraryModel()
    @AppStorage("libraryEnabled") private var enabled = false
    @AppStorage("libraryCacheGB") private var cacheGB = 0

    @State private var ownerToken = ""
    @State private var typedRecoveryCode = ""
    @State private var wroteItDown = false
    @State private var showingRecovery = false

    private var deviceName: String { Host.current().localizedName ?? "This Mac" }

    var body: some View {
        Form {
            Section {
                Toggle("Sync this library across my Macs", isOn: $enabled)
                LabeledContent("Server") {
                    Text(Settings.shared.libraryEndpoint.host ?? "—")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("You run the server yourself — kapture.sh does not store anyone else's "
                     + "library. See worker/README.md.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if enabled {
                switch model.state {
                case .ready: readySection
                case .locked: lockedSection
                case .awaitingApproval: awaitingSection
                case .disabled: setUpSection
                }
            }

            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
        .task { await model.refresh() }
        .onChange(of: enabled) { _, _ in Task { await model.restart() } }
        .sheet(isPresented: $showingRecovery) { recoverySheet }
    }

    // MARK: - Not set up yet

    @ViewBuilder private var setUpSection: some View {
        Section("Set up") {
            SecureField("Owner token", text: $ownerToken, prompt: Text("paste the token"))
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Create a library here") {
                    Task {
                        await model.create(ownerToken: ownerToken, deviceName: deviceName)
                        if model.recoveryCode != nil { showingRecovery = true }
                    }
                }
                .disabled(ownerToken.isEmpty || model.busy)

                Button("Join an existing library") {
                    Task { await model.join(ownerToken: ownerToken, deviceName: deviceName) }
                }
                .disabled(ownerToken.isEmpty || model.busy || !model.hasKey)
            }

            if !model.hasKey {
                Text("To join a library made on another Mac, either sign this Mac in to the same "
                     + "iCloud Keychain, or enter its recovery code below.")
                    .font(.caption).foregroundStyle(.secondary)
                recoveryCodeField
            }
        }
    }

    private var recoveryCodeField: some View {
        HStack {
            TextField("Recovery code", text: $typedRecoveryCode,
                      prompt: Text("XXXXX-XXXXX-…"))
                .textFieldStyle(.roundedBorder)
            Button("Unlock") {
                Task { await model.adopt(recoveryCode: typedRecoveryCode) }
            }
            .disabled(typedRecoveryCode.isEmpty || model.busy)
        }
    }

    // MARK: - Locked (F86)

    @ViewBuilder private var lockedSection: some View {
        Section("Locked") {
            // The one thing this screen must never do is look like an empty library.
            Label("This Mac has no key for the library, so it cannot read any of it yet.",
                  systemImage: "lock.fill")
                .foregroundStyle(.primary)
            Text("Your captures are not lost. They are encrypted, and the key lives in your "
                 + "iCloud Keychain — sign this Mac in to the same account, or enter the "
                 + "recovery code you wrote down.")
                .font(.caption).foregroundStyle(.secondary)
            recoveryCodeField
        }
    }

    // MARK: - Waiting for approval (F113)

    @ViewBuilder private var awaitingSection: some View {
        Section("Waiting for approval") {
            Text("Approve this Mac from one you have already set up, or from the admin "
                 + "dashboard.")
            if let fingerprint = model.fingerprint {
                LabeledContent("This Mac's code") {
                    Text(fingerprint).monospaced()
                }
            }
            Button("Check again") { Task { await model.restart() } }
                .disabled(model.busy)
        }
    }

    // MARK: - Running

    @ViewBuilder private var readySection: some View {
        Section {
            LabeledContent("Name") { Text(deviceName).foregroundStyle(.secondary) }
            Picker("Keep on this Mac", selection: $cacheGB) {
                Text("Everything").tag(0)
                Text("100 GB").tag(100)
                Text("20 GB").tag(20)
                Text("5 GB").tag(5)
            }
            Button("Show recovery code…") {
                model.revealRecoveryCode()
                showingRecovery = true
            }
        } header: {
            Text("This Mac")
        } footer: {
            Text("\"Everything\" never removes a local file, so the library on this Mac stays "
                 + "exactly what it would have been without syncing. Lower it only once you "
                 + "trust the server.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section {
            if model.devices.isEmpty {
                Text("No other Macs yet.").foregroundStyle(.secondary)
            }
            ForEach(model.devices) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.current ? "\(device.name) (this Mac)" : device.name)
                        Text(device.fingerprint).font(.caption).monospaced()
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !device.approved {
                        Button("Approve") { Task { await model.approve(device) } }
                    } else if !device.current {
                        Button("Revoke") { Task { await model.revoke(device) } }
                    }
                }
            }
        } header: {
            Text("Macs")
        } footer: {
            Text("Check the code matches the Mac in front of you before approving. Revoking "
                 + "stops a Mac syncing from now on; it does not reach what that Mac already "
                 + "holds.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - The recovery code (F85, F16)

    private var recoverySheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Write this down").font(.title2).bold()
            Text("This is the only way back into your library if this Mac and your iCloud "
                 + "Keychain both lose the key. Nobody can recover it for you — not even "
                 + "whoever runs the server, who only ever sees encrypted data.")
                .fixedSize(horizontal: false, vertical: true)

            Text(model.recoveryCode ?? "—")
                .font(.system(.title3, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))

            Toggle("I have written this down somewhere safe", isOn: $wroteItDown)

            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.recoveryCode ?? "", forType: .string)
                }
                Spacer()
                Button("Done") { showingRecovery = false }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!wroteItDown)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
