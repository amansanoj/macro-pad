import Foundation
import CoreGraphics
import Testing
@testable import macro_pad

@Suite("BLE protocol")
struct BLEProtocolTests {
    @Test("All valid events round-trip")
    func roundTrip() throws {
        for key in MacroKey.allCases {
            for transition in [ButtonTransition.pressed, .released] {
                let event = ButtonEvent(kind: .event, key: key, transition: transition, sequence: 42)
                #expect(try ButtonEvent(data: event.encoded) == event)
            }
        }
    }

    @Test("Malformed packets are rejected")
    func malformedPackets() {
        #expect(throws: ProtocolError.invalidLength) {
            try ButtonEvent(data: Data([1, 1, 1]))
        }
        #expect(throws: ProtocolError.invalidMessageType) {
            try ButtonEvent(data: Data([1, 9, 1, 1, 0]))
        }
        #expect(throws: ProtocolError.invalidKey) {
            try ButtonEvent(data: Data([1, 1, 5, 1, 0]))
        }
        #expect(throws: ProtocolError.invalidTransition) {
            try ButtonEvent(data: Data([1, 1, 1, 2, 0]))
        }
    }

    @Test("Unsupported protocol versions are rejected")
    func unsupportedVersion() {
        #expect(throws: ProtocolError.unsupportedVersion(2)) {
            try ButtonEvent(data: Data([2, 1, 1, 1, 0]))
        }
    }
}

@Suite("Key state machine")
struct KeyStateMachineTests {
    @Test("Executes once on key-down and never on key-up")
    func transitions() {
        var state = KeyStateMachine()
        let down = ButtonEvent(kind: .event, key: .one, transition: .pressed, sequence: 1)
        let up = ButtonEvent(kind: .event, key: .one, transition: .released, sequence: 2)
        let firstDown = state.consume(down)
        let duplicateDown = state.consume(down)
        let released = state.consume(up)
        #expect(firstDown)
        #expect(!duplicateDown)
        #expect(!released)
        #expect(state.pressedKeys.isEmpty)
    }

    @Test("Independent simultaneous keys are preserved")
    func simultaneousKeys() {
        var state = KeyStateMachine()
        let keyOne = state.consume(ButtonEvent(kind: .event, key: .one, transition: .pressed, sequence: 1))
        let keyFour = state.consume(ButtonEvent(kind: .event, key: .four, transition: .pressed, sequence: 2))
        #expect(keyOne)
        #expect(keyFour)
        #expect(state.pressedKeys == [.one, .four])
        let release = state.consume(ButtonEvent(kind: .event, key: .one, transition: .released, sequence: 3))
        #expect(!release)
        #expect(state.pressedKeys == [.four])
    }

    @Test("State synchronization never dispatches")
    func stateSync() {
        var state = KeyStateMachine()
        let sync = ButtonEvent(kind: .stateSync, key: .two, transition: .pressed, sequence: 9)
        let dispatched = state.consume(sync)
        #expect(!dispatched)
        #expect(state.pressedKeys == [.two])
    }

    @Test("GPIO mapping matches hardware")
    func gpioMapping() {
        #expect(MacroKey.one.gpio == 13)
        #expect(MacroKey.two.gpio == 14)
        #expect(MacroKey.three.gpio == 33)
        #expect(MacroKey.four.gpio == 32)
    }
}

@Suite("Configuration")
@MainActor
struct ConfigurationTests {
    @Test("Configuration persists")
    func persistence() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(fileURL: directory.appending(path: "configuration.json"))
        var configuration = AppConfiguration()
        configuration.keys[0].actionKind = .openURL
        configuration.keys[0].urlString = "https://example.com"
        try store.save(configuration)
        #expect(try store.load() == configuration)
    }

    @Test("Missing fields migrate to four defaults")
    func migration() throws {
        let data = Data(#"{"version":1,"keys":[]}"#.utf8)
        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)
        #expect(configuration.keys.map(\.id) == MacroKey.allCases)
        #expect(configuration.automaticallyReconnect)
        #expect(configuration.appearance == .system)
    }

    @Test("Newer configuration is preserved and rejected")
    func futureVersion() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "configuration.json")
        try Data(#"{"version":99,"keys":[]}"#.utf8).write(to: url)
        let store = ConfigurationStore(fileURL: url)
        do {
            _ = try store.load()
            Issue.record("Expected a future-version error")
        } catch let error as ConfigurationStoreError {
            guard case .unsupportedVersion(let version) = error else {
                Issue.record("Unexpected configuration error")
                return
            }
            #expect(version == 99)
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

@Suite("Action validation")
struct ActionValidationTests {
    @Test("Only complete HTTP and HTTPS URLs pass")
    func urls() {
        #expect(URLValidator.validatedHTTPURL("https://example.com/path") != nil)
        #expect(URLValidator.validatedHTTPURL("http://localhost:8080") != nil)
        #expect(URLValidator.validatedHTTPURL("file:///tmp/example") == nil)
        #expect(URLValidator.validatedHTTPURL("example.com") == nil)
    }

    @Test("Process failures report status and stderr")
    func commandFailure() async throws {
        let result = try await ActionExecutor.runProcess(
            executable: "/usr/bin/false",
            arguments: [],
            timeout: 2
        )
        #expect(result.status != 0)
        #expect(!result.timedOut)
    }

    @Test("Processes are terminated at timeout")
    func commandTimeout() async throws {
        let result = try await ActionExecutor.runProcess(
            executable: "/bin/sleep",
            arguments: ["2"],
            timeout: 0.1
        )
        #expect(result.timedOut)
    }
}

@Suite("Action presentation")
struct ActionPresentationTests {
    @Test("URLs use a readable hostname without changing the destination")
    func readableURL() {
        var configuration = KeyConfiguration(id: .one)
        configuration.actionKind = .openURL
        configuration.urlString = "https://www.amansanoj.com/some/long/path"
        let presentation = ActionPresentation(configuration: configuration)

        #expect(presentation.title == "amansanoj.com")
        #expect(presentation.tooltip == configuration.urlString)
    }

    @Test("Incomplete actions are presented as not configured")
    func incompleteActions() {
        for kind in [
            ActionKind.launchApplication,
            .keyboardShortcut,
            .openURL,
            .appleShortcut,
            .shellCommand
        ] {
            var configuration = KeyConfiguration(id: .one)
            configuration.actionKind = kind

            #expect(!configuration.isActionConfigured)
            #expect(ActionPresentation(configuration: configuration).title == "Not configured")
        }
    }

    @Test("Media controls use function-specific symbols")
    func mediaSymbols() {
        #expect(MediaAction.playPause.symbolName == "playpause.fill")
        #expect(MediaAction.next.symbolName == "forward.end.fill")
        #expect(MediaAction.previous.symbolName == "backward.end.fill")
        #expect(MediaAction.volumeUp.symbolName != MediaAction.volumeDown.symbolName)
        #expect(MediaAction.mute.symbolName == "speaker.slash.fill")
    }

    @Test("Shell previews do not expose configured arguments")
    func safeCommandSummary() {
        var configuration = KeyConfiguration(id: .one)
        configuration.actionKind = .shellCommand
        configuration.executablePath = "/usr/bin/open"
        configuration.arguments = ["--args", "secret-value"]
        configuration.shellCommandEnabled = true
        let presentation = ActionPresentation(configuration: configuration)

        #expect(presentation.title == "open")
        #expect(!presentation.tooltip.contains("secret-value"))
    }
}

@Suite("Shortcut recording")
struct ShortcutRecordingTests {
    @Test("Quartz events preserve key codes and modifiers", arguments: [
        (keyCode: UInt16(21), flags: CGEventFlags([.maskCommand, .maskShift]), display: "⇧⌘4"),
        (keyCode: UInt16(20), flags: CGEventFlags([.maskCommand, .maskShift]), display: "⇧⌘3"),
        (keyCode: UInt16(8), flags: CGEventFlags.maskCommand, display: "⌘C"),
        (keyCode: UInt16(12), flags: CGEventFlags.maskCommand, display: "⌘Q"),
        (keyCode: UInt16(49), flags: CGEventFlags.maskCommand, display: "⌘Space"),
        (keyCode: UInt16(48), flags: CGEventFlags.maskCommand, display: "⌘⇥"),
        (keyCode: UInt16(12), flags: CGEventFlags([.maskControl, .maskCommand]), display: "⌃⌘Q")
    ])
    func eventMapping(sample: (keyCode: UInt16, flags: CGEventFlags, display: String)) throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: sample.keyCode, keyDown: true))
        event.flags = sample.flags

        let shortcut = try #require(ShortcutKeyCatalog.definition(for: event))

        #expect(shortcut.keyCode == sample.keyCode)
        #expect(shortcut.displayText == sample.display)
    }

    @Test("Manual entry covers system shortcut examples")
    func manualCatalog() {
        for keyCode: UInt16 in [21, 20, 8, 12, 49, 48] {
            #expect(ShortcutKeyCatalog.manualKeys.contains { $0.keyCode == keyCode })
        }
    }

    @Test("Permission denial never enters recording mode")
    @MainActor
    func permissionDenial() {
        let view = ShortcutRecorderView(dependencies: .init(
            isAccessibilityTrusted: { false },
            createEventTap: { _, _, _ in nil }
        ))
        var failure: String?
        view.onFailure = { failure = $0 }

        #expect(!view.startRecording())
        #expect(!view.isRecording)
        #expect(failure?.contains("Accessibility permission") == true)
    }

    @Test("Event-tap failure never enters recording mode")
    @MainActor
    func eventTapFailure() {
        let view = ShortcutRecorderView(dependencies: .init(
            isAccessibilityTrusted: { true },
            createEventTap: { _, _, _ in nil }
        ))
        var failure: String?
        view.onFailure = { failure = $0 }

        #expect(!view.startRecording())
        #expect(!view.isRecording)
        #expect(failure?.contains("could not start") == true)
    }
}

@Suite("Application profiles")
@MainActor
struct ApplicationProfileTests {
    @Test("Default is used when no application profile exists")
    func defaultFallback() {
        let configuration = configuredDefaults()
        let resolved = AssignmentResolver.resolve(
            key: .one,
            foregroundBundleIdentifier: "com.example.Unconfigured",
            configuration: configuration
        )
        #expect(resolved.origin == .defaultProfile)
        #expect(resolved.configuration?.urlString == "https://default.example")
    }

    @Test("Application override replaces Default")
    func applicationOverride() {
        let configuration = configurationWithProfile(mode: .override)
        let resolved = AssignmentResolver.resolve(
            key: .one,
            foregroundBundleIdentifier: "com.example.Editor",
            configuration: configuration
        )
        #expect(resolved.origin == .override)
        #expect(resolved.configuration?.urlString == "https://override.example")
    }

    @Test("Inheritance reflects later Default changes")
    func dynamicInheritance() {
        var configuration = configurationWithProfile(mode: .inheritDefault)
        configuration.keys[0].urlString = "https://changed.example"
        let resolved = AssignmentResolver.resolve(
            key: .one,
            foregroundBundleIdentifier: "com.example.Editor",
            configuration: configuration
        )
        #expect(resolved.origin == .inherited)
        #expect(resolved.configuration?.urlString == "https://changed.example")
    }

    @Test("Disabled assignment resolves to no action")
    func disabledKey() {
        let configuration = configurationWithProfile(mode: .disabled)
        let resolved = AssignmentResolver.resolve(
            key: .one,
            foregroundBundleIdentifier: "com.example.Editor",
            configuration: configuration
        )
        #expect(resolved.origin == .disabled)
        #expect(resolved.configuration == nil)
        #expect(!resolved.canExecute)
    }

    @Test("Partial profiles inherit untouched keys")
    func partialOverrides() {
        var configuration = configurationWithProfile(mode: .override)
        configuration.applicationProfiles[0].assignments[1].mode = .disabled
        #expect(AssignmentResolver.resolve(
            key: .one,
            foregroundBundleIdentifier: "com.example.Editor",
            configuration: configuration
        ).origin == .override)
        #expect(AssignmentResolver.resolve(
            key: .two,
            foregroundBundleIdentifier: "com.example.Editor",
            configuration: configuration
        ).origin == .disabled)
        #expect(AssignmentResolver.resolve(
            key: .three,
            foregroundBundleIdentifier: "com.example.Editor",
            configuration: configuration
        ).origin == .inherited)
    }

    @Test("Application switching changes effective assignments")
    func applicationSwitching() {
        let configuration = configurationWithProfile(mode: .override)
        let editor = AssignmentResolver.resolve(
            key: .one,
            foregroundBundleIdentifier: "com.example.Editor",
            configuration: configuration
        )
        let finder = AssignmentResolver.resolve(
            key: .one,
            foregroundBundleIdentifier: "com.apple.finder",
            configuration: configuration
        )
        #expect(editor.configuration?.urlString == "https://override.example")
        #expect(finder.configuration?.urlString == "https://default.example")
    }

    @Test("Missing foreground identity safely uses Default")
    func missingBundleIdentifier() {
        let resolved = AssignmentResolver.resolve(
            key: .one,
            foregroundBundleIdentifier: nil,
            configuration: configurationWithProfile(mode: .override)
        )
        #expect(resolved.origin == .defaultProfile)
        #expect(resolved.configuration?.urlString == "https://default.example")
    }

    @Test("Profiles and overrides persist")
    func persistence() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(fileURL: directory.appending(path: "configuration.json"))
        let configuration = configurationWithProfile(mode: .override)
        try store.save(configuration)
        #expect(try store.load() == configuration)
    }

    @Test("Version 1 assignments migrate to Default")
    func migration() throws {
        let data = Data(#"{"version":1,"keys":[{"id":1,"actionKind":"openURL","urlString":"https://legacy.example"}]}"#.utf8)
        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)
        #expect(configuration.version == AppConfiguration.currentVersion)
        #expect(configuration.keys[0].urlString == "https://legacy.example")
        #expect(configuration.applicationProfiles.isEmpty)
    }

    @Test("Deleting an active profile falls back to Default")
    func profileDeletion() {
        var configuration = configurationWithProfile(mode: .override)
        configuration.applicationProfiles.removeAll { $0.bundleIdentifier == "com.example.Editor" }
        let resolved = AssignmentResolver.resolve(
            key: .one,
            foregroundBundleIdentifier: "com.example.Editor",
            configuration: configuration
        )
        #expect(resolved.origin == .defaultProfile)
        #expect(resolved.configuration?.urlString == "https://default.example")
    }

    @Test("Editing one profile does not change another execution context")
    func editingIsolation() {
        var configuration = configurationWithProfile(mode: .override)
        var zen = ApplicationProfile(bundleIdentifier: "app.zen-browser.zen", displayName: "Zen")
        zen.assignments[0].mode = .override
        zen.assignments[0].override = urlAssignment(.one, "https://zen.example")
        configuration.applicationProfiles.append(zen)

        configuration.applicationProfiles[0].assignments[0].override?.urlString = "https://discord-edit.example"
        let zenExecution = AssignmentResolver.resolve(
            key: .one,
            foregroundBundleIdentifier: "app.zen-browser.zen",
            configuration: configuration
        )
        #expect(zenExecution.configuration?.urlString == "https://zen.example")
    }

    @Test("Resolved action remains stable when activation changes")
    func singleExecutionSnapshot() {
        var configuration = configurationWithProfile(mode: .override)
        let actionAtKeyDown = AssignmentResolver.resolve(
            key: .one,
            foregroundBundleIdentifier: "com.example.Editor",
            configuration: configuration
        ).configuration
        configuration.applicationProfiles[0].assignments[0].override?.urlString = "https://later.example"
        #expect(actionAtKeyDown?.urlString == "https://override.example")
    }

    private func configuredDefaults() -> AppConfiguration {
        var configuration = AppConfiguration()
        configuration.keys[0] = urlAssignment(.one, "https://default.example")
        return configuration
    }

    private func configurationWithProfile(mode: ProfileAssignmentMode) -> AppConfiguration {
        var configuration = configuredDefaults()
        var profile = ApplicationProfile(bundleIdentifier: "com.example.Editor", displayName: "Editor")
        profile.assignments[0].mode = mode
        if mode == .override {
            profile.assignments[0].override = urlAssignment(.one, "https://override.example")
        }
        configuration.applicationProfiles = [profile]
        return configuration
    }

    private func urlAssignment(_ key: MacroKey, _ url: String) -> KeyConfiguration {
        var assignment = KeyConfiguration(id: key)
        assignment.actionKind = .openURL
        assignment.urlString = url
        return assignment
    }
}

struct MockBLEEventSource {
    let send: (ButtonEvent) -> Void

    func press(_ key: MacroKey, sequence: UInt8 = 1) {
        send(ButtonEvent(kind: .event, key: key, transition: .pressed, sequence: sequence))
        send(ButtonEvent(kind: .event, key: key, transition: .released, sequence: sequence &+ 1))
    }
}

@Suite("Mock event source")
@MainActor
struct MockEventSourceTests {
    @Test("Mock source uses the application event pipeline")
    func mockPipeline() {
        var state = KeyStateMachine()
        var dispatches: [MacroKey] = []
        let source = MockBLEEventSource { event in
            if state.consume(event) {
                dispatches.append(event.key)
            }
        }
        source.press(.one)
        source.press(.two, sequence: 10)
        #expect(dispatches == [.one, .two])
        #expect(state.pressedKeys.isEmpty)
    }
}
