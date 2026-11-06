import AppKit
import ApplicationServices
import Foundation
import Observation
import ServiceManagement
import UniformTypeIdentifiers

enum ConfigurationStoreError: LocalizedError, Equatable {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "Configuration version \(version) is newer than this version of macro-pad supports."
        }
    }
}

struct ConfigurationStore {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = base.appending(path: "macro-pad/configuration.json")
        }
    }

    func load() throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return AppConfiguration()
        }
        let data = try Data(contentsOf: fileURL)
        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)
        guard configuration.version <= AppConfiguration.currentVersion else {
            throw ConfigurationStoreError.unsupportedVersion(configuration.version)
        }
        return configuration
    }

    func loadRecoveringFromCorruption() -> (AppConfiguration, String?) {
        do {
            return (try load(), nil)
        } catch {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return (AppConfiguration(), error.localizedDescription)
            }
            let formatter = ISO8601DateFormatter()
            let suffix = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(suffix).json")
            do {
                try FileManager.default.moveItem(at: fileURL, to: backup)
                return (AppConfiguration(), "The configuration could not be read. It was preserved at \(backup.path).")
            } catch {
                return (AppConfiguration(), "The configuration could not be read and remains at \(fileURL.path).")
            }
        }
    }

    func save(_ configuration: AppConfiguration) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        try data.write(to: fileURL, options: .atomic)
    }
}

@MainActor
@Observable
final class AppModel {
    var configuration: AppConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            synchronizeBLEPreferences()
            save()
        }
    }
    private(set) var pressedKeys: Set<MacroKey> = []
    private(set) var persistenceMessage: String?
    private(set) var simulationMode = false
    private(set) var launchAtLogin = false
    private(set) var activeApplication: ForegroundApplication?
    var editingProfileID: String?
    let ble: BLEController
    let executor: ActionExecutor

    private let store: ConfigurationStore
    private let applicationMonitor: ApplicationContextMonitor
    private var stateMachine = KeyStateMachine()

    convenience init() {
        self.init(
            store: ConfigurationStore(),
            ble: BLEController(),
            executor: ActionExecutor(),
            applicationMonitor: ApplicationContextMonitor()
        )
    }

    init(
        store: ConfigurationStore,
        ble: BLEController,
        executor: ActionExecutor,
        applicationMonitor: ApplicationContextMonitor? = nil,
        startServices: Bool = true
    ) {
        self.store = store
        self.ble = ble
        self.executor = executor
        self.applicationMonitor = applicationMonitor ?? ApplicationContextMonitor()
        let loaded = store.loadRecoveringFromCorruption()
        configuration = loaded.0
        persistenceMessage = loaded.1
        launchAtLogin = SMAppService.mainApp.status == .enabled
        synchronizeBLEPreferences()
        ble.onEvent = { [weak self] event in
            self?.receive(event)
        }
        ble.onSelectedPeripheral = { [weak self] identifier, name in
            self?.configuration.selectedPeripheralID = identifier
            self?.configuration.selectedPeripheralName = name
        }
        ble.onConnectionReset = { [weak self] in
            self?.resetInputState()
        }
        self.applicationMonitor.onChange = { [weak self] application in
            self?.receiveApplicationActivation(application)
        }
        if startServices {
            self.applicationMonitor.start()
            ble.restoreAutomaticConnection()
        }
    }

    var selectedKeyID: MacroKey = .one

    var editingProfile: ApplicationProfile? {
        guard let editingProfileID else { return nil }
        return configuration.applicationProfiles.first { $0.bundleIdentifier == editingProfileID }
    }

    var activeExecutionProfile: ApplicationProfile? {
        guard let bundleIdentifier = activeApplication?.bundleIdentifier else { return nil }
        return configuration.applicationProfiles.first { $0.bundleIdentifier == bundleIdentifier }
    }

    var activeExecutionProfileName: String {
        activeExecutionProfile?.displayName ?? "Default"
    }

    var editingProfileName: String {
        editingProfile?.displayName ?? "Default"
    }

    var editingProfileHasCustomAssignments: Bool {
        editingProfile?.assignments.contains { $0.mode != .inheritDefault } == true
    }

    var editingAssignments: [ResolvedKeyAssignment] {
        MacroKey.allCases.map { key in
            AssignmentResolver.resolve(
                key: key,
                foregroundBundleIdentifier: editingProfileID,
                configuration: configuration
            )
        }
    }

    var executionAssignments: [ResolvedKeyAssignment] {
        MacroKey.allCases.map { key in
            AssignmentResolver.resolve(
                key: key,
                foregroundBundleIdentifier: activeApplication?.bundleIdentifier,
                configuration: configuration
            )
        }
    }

    var selectedResolvedAssignment: ResolvedKeyAssignment {
        AssignmentResolver.resolve(
            key: selectedKeyID,
            foregroundBundleIdentifier: editingProfileID,
            configuration: configuration
        )
    }

    var selectedConfiguration: KeyConfiguration {
        selectedResolvedAssignment.configuration ?? KeyConfiguration(id: selectedKeyID)
    }

    var selectedAssignmentMode: ProfileAssignmentMode? {
        guard let profile = editingProfile else { return nil }
        return profile.assignments.first(where: { $0.id == selectedKeyID })?.mode ?? .inheritDefault
    }

    func updateSelected(_ update: (inout KeyConfiguration) -> Void) {
        if let editingProfileID {
            guard let profileIndex = configuration.applicationProfiles.firstIndex(where: {
                $0.bundleIdentifier == editingProfileID
            }), let assignmentIndex = configuration.applicationProfiles[profileIndex].assignments.firstIndex(where: {
                $0.id == selectedKeyID
            }), configuration.applicationProfiles[profileIndex].assignments[assignmentIndex].mode == .override else {
                return
            }
            if configuration.applicationProfiles[profileIndex].assignments[assignmentIndex].override == nil {
                configuration.applicationProfiles[profileIndex].assignments[assignmentIndex].override = defaultAssignment(for: selectedKeyID)
            }
            update(&configuration.applicationProfiles[profileIndex].assignments[assignmentIndex].override!)
        } else {
            guard let index = configuration.keys.firstIndex(where: { $0.id == selectedKeyID }) else { return }
            update(&configuration.keys[index])
        }
    }

    func setSelectedAssignmentMode(_ mode: ProfileAssignmentMode) {
        guard let editingProfileID,
              let profileIndex = configuration.applicationProfiles.firstIndex(where: {
                  $0.bundleIdentifier == editingProfileID
              }), let assignmentIndex = configuration.applicationProfiles[profileIndex].assignments.firstIndex(where: {
                  $0.id == selectedKeyID
              }) else { return }

        var assignment = configuration.applicationProfiles[profileIndex].assignments[assignmentIndex]
        assignment.mode = mode
        switch mode {
        case .inheritDefault:
            assignment.override = nil
        case .override:
            if assignment.override == nil {
                assignment.override = defaultAssignment(for: selectedKeyID)
            }
        case .disabled:
            break
        }
        configuration.applicationProfiles[profileIndex].assignments[assignmentIndex] = assignment
    }

    func resetSelectedKey() {
        resetKey(selectedKeyID)
    }

    func resetKey(_ key: MacroKey) {
        if let editingProfileID,
           let profileIndex = configuration.applicationProfiles.firstIndex(where: {
               $0.bundleIdentifier == editingProfileID
           }), let assignmentIndex = configuration.applicationProfiles[profileIndex].assignments.firstIndex(where: {
               $0.id == key
           }), configuration.applicationProfiles[profileIndex].assignments[assignmentIndex].mode == .override {
            if let current = configuration.applicationProfiles[profileIndex].assignments[assignmentIndex].override {
                ApplicationIconCache.shared.invalidate(current)
            }
            configuration.applicationProfiles[profileIndex].assignments[assignmentIndex].override = KeyConfiguration(id: key)
        } else if editingProfileID == nil,
                  let index = configuration.keys.firstIndex(where: { $0.id == key }) {
            ApplicationIconCache.shared.invalidate(configuration.keys[index])
            configuration.keys[index] = KeyConfiguration(id: key)
        }
    }

    func testAction(for key: MacroKey) {
        let resolved = AssignmentResolver.resolve(
            key: key,
            foregroundBundleIdentifier: editingProfileID,
            configuration: configuration
        )
        guard resolved.origin != .disabled, let assignment = resolved.configuration else { return }
        executor.execute(assignment)
    }

    func resetAllKeys() {
        if let editingProfileID,
           let profileIndex = configuration.applicationProfiles.firstIndex(where: {
               $0.bundleIdentifier == editingProfileID
           }) {
            configuration.applicationProfiles[profileIndex].assignments = MacroKey.allCases.map {
                ProfileKeyAssignment(id: $0)
            }
        } else {
            configuration.keys = MacroKey.allCases.map { KeyConfiguration(id: $0) }
        }
    }

    func connectOrDisconnect() {
        if ble.connectionState == .connected || ble.connectionState == .connecting {
            ble.disconnect()
        } else {
            ble.connect()
        }
    }

    func forgetDevice() {
        ble.forgetDevice()
        configuration.selectedPeripheralID = nil
        configuration.selectedPeripheralName = nil
    }

    func receive(_ event: ButtonEvent) {
        let shouldExecute = stateMachine.consume(event)
        pressedKeys = stateMachine.pressedKeys
        guard shouldExecute,
              let assignment = AssignmentResolver.resolve(
                  key: event.key,
                  foregroundBundleIdentifier: activeApplication?.bundleIdentifier,
                  configuration: configuration
              ).configuration else { return }
        executor.execute(assignment)
    }

    func setSimulationMode(_ enabled: Bool) {
        simulationMode = enabled
        if !enabled {
            stateMachine.reset()
            pressedKeys = []
        }
    }

    private func resetInputState() {
        stateMachine.reset()
        pressedKeys = []
    }

    func simulatePress(_ key: MacroKey) {
        guard simulationMode else { return }
        let next = UInt8.random(in: 0...255)
        receive(ButtonEvent(kind: .event, key: key, transition: .pressed, sequence: next))
        receive(ButtonEvent(kind: .event, key: key, transition: .released, sequence: next &+ 1))
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            persistenceMessage = "Launch at login could not be changed: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func requestAccessibilityPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Application"
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            ApplicationIconCache.shared.invalidate(selectedConfiguration)
            updateSelected {
                $0.applicationBookmark = bookmark
                $0.applicationName = url.deletingPathExtension().lastPathComponent
            }
        } catch {
            persistenceMessage = "The application reference could not be saved: \(error.localizedDescription)"
        }
    }

    func addApplicationProfile() {
        let panel = NSOpenPanel()
        panel.title = "Add Application Profile"
        panel.prompt = "Add Profile"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier,
              !bundleIdentifier.isEmpty else {
            persistenceMessage = "The selected item does not have a valid application bundle identifier."
            return
        }
        if configuration.applicationProfiles.contains(where: { $0.bundleIdentifier == bundleIdentifier }) {
            editingProfileID = bundleIdentifier
            return
        }
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let profile = ApplicationProfile(
                bundleIdentifier: bundleIdentifier,
                displayName: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent,
                applicationBookmark: bookmark
            )
            configuration.applicationProfiles.append(profile)
            configuration.applicationProfiles.sort {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            editingProfileID = bundleIdentifier
        } catch {
            persistenceMessage = "The application profile could not be saved: \(error.localizedDescription)"
        }
    }

    func deleteEditingProfile() {
        guard let editingProfileID else { return }
        configuration.applicationProfiles.removeAll { $0.bundleIdentifier == editingProfileID }
        ProfileApplicationIconCache.shared.invalidate(bundleIdentifier: editingProfileID)
        self.editingProfileID = nil
    }

    private func defaultAssignment(for key: MacroKey) -> KeyConfiguration {
        configuration.keys.first(where: { $0.id == key }) ?? KeyConfiguration(id: key)
    }

    private func receiveApplicationActivation(_ application: ForegroundApplication?) {
        activeApplication = application
        guard let application,
              let profileIndex = configuration.applicationProfiles.firstIndex(where: {
                  $0.bundleIdentifier == application.bundleIdentifier
              }), configuration.applicationProfiles[profileIndex].displayName != application.displayName else {
            return
        }
        configuration.applicationProfiles[profileIndex].displayName = application.displayName
        ProfileApplicationIconCache.shared.invalidate(bundleIdentifier: application.bundleIdentifier)
    }

    private func synchronizeBLEPreferences() {
        ble.selectedPeripheralID = configuration.selectedPeripheralID
        ble.automaticallyReconnect = configuration.automaticallyReconnect
    }

    private func save() {
        do {
            try store.save(configuration)
        } catch {
            persistenceMessage = "Configuration could not be saved: \(error.localizedDescription)"
        }
    }
}

#if DEBUG
@MainActor
enum PreviewFixtures {
    static func model(profile: Bool = false, device: Bool = false) -> AppModel {
        let store = ConfigurationStore(
            fileURL: FileManager.default.temporaryDirectory
                .appending(path: "macro-pad-preview-\(UUID().uuidString).json")
        )
        let model = AppModel(
            store: store,
            ble: BLEController(),
            executor: ActionExecutor(),
            startServices: false
        )
        var configuration = AppConfiguration()
        configuration.appearance = profile || device ? .light : .dark
        configuration.keys = defaultAssignments()

        if profile {
            var discord = ApplicationProfile(
                bundleIdentifier: "com.hnc.Discord",
                displayName: "Discord",
                applicationBookmark: bookmark(for: "/Applications/Discord.app")
            )
            var shortcut = KeyConfiguration(id: .one)
            shortcut.actionKind = .keyboardShortcut
            shortcut.shortcut = ShortcutDefinition(
                keyCode: 40,
                keyLabel: "K",
                command: true
            )
            discord.assignments[0].mode = .override
            discord.assignments[0].override = shortcut
            discord.assignments[1].mode = .inheritDefault
            discord.assignments[2].mode = .disabled
            discord.assignments[3].mode = .inheritDefault
            configuration.applicationProfiles = [discord]
            model.editingProfileID = discord.bundleIdentifier
            model.selectedKeyID = .one
        } else {
            model.selectedKeyID = .three
        }

        if device {
            configuration.selectedPeripheralID = UUID(uuidString: "7A4D1000-5A7E-4D2F-9C6B-4B0A3E6D0100")
            configuration.selectedPeripheralName = BLEProtocol.deviceName
            configuration.automaticallyReconnect = true
        }

        model.configuration = configuration
        return model
    }

    private static func defaultAssignments() -> [KeyConfiguration] {
        var safari = KeyConfiguration(id: .one)
        safari.actionKind = .launchApplication
        safari.applicationName = "Safari"
        safari.applicationBookmark = bookmark(for: "/Applications/Safari.app")

        var terminal = KeyConfiguration(id: .two)
        terminal.actionKind = .launchApplication
        terminal.applicationName = "Terminal"
        terminal.applicationBookmark = bookmark(for: "/System/Applications/Utilities/Terminal.app")

        var screenshot = KeyConfiguration(id: .three)
        screenshot.actionKind = .keyboardShortcut
        screenshot.shortcut = ShortcutDefinition(
            keyCode: 21,
            keyLabel: "4",
            command: true,
            shift: true
        )

        var github = KeyConfiguration(id: .four)
        github.actionKind = .openURL
        github.urlString = "https://github.com/amansanoj/macro-pad"
        return [safari, terminal, screenshot, github]
    }

    private static func bookmark(for path: String) -> Data? {
        try? URL(fileURLWithPath: path).bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
}
#endif
