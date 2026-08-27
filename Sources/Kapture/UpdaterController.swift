// In-app updates via Sparkle. The appcast lives at kapture.sh/appcast.xml and redirects to the
// signed DMG attached to a GitHub release, so the Worker never serves the binary itself.
//
// Every update is verified twice before it runs: Sparkle checks the EdDSA signature against
// SUPublicEDKey in Info.plist, and macOS checks the Developer ID signature and notarization.
import AppKit
import Sparkle
import KaptureCore

@MainActor
final class UpdaterController {
    static let shared = UpdaterController()

    /// nil in a build whose Info.plist carries no public key — a development bundle, where an
    /// updater would either refuse every update or, worse, accept an unsigned one.
    private let controller: SPUStandardUpdaterController?

    private init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        guard let key, !key.isEmpty, !key.hasPrefix("REPLACE") else {
            Log.shell.info("updates disabled: no SUPublicEDKey in this build")
            controller = nil
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil, userDriverDelegate: nil)
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        guard let controller else {
            NSWorkspace.shared.open(URL(string: "https://kapture.sh/download")!)
            return
        }
        controller.checkForUpdates(nil)
    }

    /// Menu validation: Sparkle refuses a check while one is already running.
    var canCheckNow: Bool { controller?.updater.canCheckForUpdates ?? true }
}
