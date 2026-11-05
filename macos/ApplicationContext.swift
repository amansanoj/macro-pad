import AppKit

struct ForegroundApplication: Equatable {
    let bundleIdentifier: String
    let displayName: String
    let applicationURL: URL?
    let processIdentifier: pid_t
}

@MainActor
final class ApplicationContextMonitor {
    var onChange: ((ForegroundApplication?) -> Void)?

    private let workspace: NSWorkspace
    private let ownBundleIdentifier: String?
    private var activationObserver: NSObjectProtocol?
    private(set) var currentApplication: ForegroundApplication?

    init(
        workspace: NSWorkspace = .shared,
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        self.workspace = workspace
        self.ownBundleIdentifier = ownBundleIdentifier
    }

    deinit {
        if let activationObserver {
            workspace.notificationCenter.removeObserver(activationObserver)
        }
    }

    func start() {
        guard activationObserver == nil else { return }
        activationObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleActivation(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            }
        }
        handleActivation(workspace.frontmostApplication)
    }

    private func handleActivation(_ application: NSRunningApplication?) {
        guard let application,
              let bundleIdentifier = application.bundleIdentifier,
              !bundleIdentifier.isEmpty else {
            return
        }

        // Configuration and Settings bring macro-pad forward. Ignore only our own
        // activation so physical keys continue using the last meaningful external
        // context. The next external activation (including Finder) replaces it.
        guard bundleIdentifier != ownBundleIdentifier else { return }

        let next = ForegroundApplication(
            bundleIdentifier: bundleIdentifier,
            displayName: application.localizedName ?? bundleIdentifier,
            applicationURL: application.bundleURL,
            processIdentifier: application.processIdentifier
        )
        guard next != currentApplication else { return }
        currentApplication = next
        onChange?(next)
    }
}
