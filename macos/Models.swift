import Foundation

enum BLEProtocol {
    static let version: UInt8 = 1
    static let serviceUUID = "7A4D1000-5A7E-4D2F-9C6B-4B0A3E6D0100"
    static let eventCharacteristicUUID = "7A4D1001-5A7E-4D2F-9C6B-4B0A3E6D0100"
    static let deviceName = "macro-pad"
    static let packetLength = 5
}

enum MacroKey: UInt8, CaseIterable, Codable, Identifiable, Sendable {
    case one = 1
    case two
    case three
    case four

    var id: UInt8 { rawValue }
    var title: String { "Key \(rawValue)" }

    var gpio: Int {
        switch self {
        case .one: 13
        case .two: 14
        case .three: 33
        case .four: 32
        }
    }
}

enum ButtonTransition: UInt8, Codable, Sendable {
    case released = 0
    case pressed = 1
}

enum ButtonMessageKind: UInt8, Codable, Sendable {
    case event = 1
    case stateSync = 2
}

struct ButtonEvent: Equatable, Sendable {
    let kind: ButtonMessageKind
    let key: MacroKey
    let transition: ButtonTransition
    let sequence: UInt8

    var encoded: Data {
        Data([BLEProtocol.version, kind.rawValue, key.rawValue, transition.rawValue, sequence])
    }

    init(kind: ButtonMessageKind, key: MacroKey, transition: ButtonTransition, sequence: UInt8) {
        self.kind = kind
        self.key = key
        self.transition = transition
        self.sequence = sequence
    }

    init(data: Data) throws {
        guard data.count == BLEProtocol.packetLength else {
            throw ProtocolError.invalidLength
        }
        guard data[0] == BLEProtocol.version else {
            throw ProtocolError.unsupportedVersion(data[0])
        }
        guard let kind = ButtonMessageKind(rawValue: data[1]) else {
            throw ProtocolError.invalidMessageType
        }
        guard let key = MacroKey(rawValue: data[2]) else {
            throw ProtocolError.invalidKey
        }
        guard let transition = ButtonTransition(rawValue: data[3]) else {
            throw ProtocolError.invalidTransition
        }
        self.init(kind: kind, key: key, transition: transition, sequence: data[4])
    }
}

enum ProtocolError: LocalizedError, Equatable {
    case invalidLength
    case unsupportedVersion(UInt8)
    case invalidMessageType
    case invalidKey
    case invalidTransition

    var errorDescription: String? {
        switch self {
        case .invalidLength: "The device sent a packet with an invalid length."
        case .unsupportedVersion(let version): "Protocol version \(version) is not supported."
        case .invalidMessageType: "The device sent an unknown message type."
        case .invalidKey: "The device sent an invalid key identifier."
        case .invalidTransition: "The device sent an invalid key state."
        }
    }
}

enum ActionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case launchApplication
    case keyboardShortcut
    case openURL
    case appleShortcut
    case shellCommand
    case mediaControl

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "No Action"
        case .launchApplication: "Launch Application"
        case .keyboardShortcut: "Keyboard Shortcut"
        case .openURL: "Open URL"
        case .appleShortcut: "Apple Shortcut"
        case .shellCommand: "Shell Command"
        case .mediaControl: "Media Control"
        }
    }

    var symbol: String {
        switch self {
        case .none: "minus.circle"
        case .launchApplication: "app"
        case .keyboardShortcut: "keyboard"
        case .openURL: "link"
        case .appleShortcut: "square.stack.3d.up"
        case .shellCommand: "terminal"
        case .mediaControl: "playpause"
        }
    }
}

enum MediaAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case playPause
    case next
    case previous
    case volumeUp
    case volumeDown
    case mute

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playPause: "Play/Pause"
        case .next: "Next"
        case .previous: "Previous"
        case .volumeUp: "Volume Up"
        case .volumeDown: "Volume Down"
        case .mute: "Mute"
        }
    }
}

struct ShortcutDefinition: Codable, Equatable, Sendable {
    var keyCode: UInt16 = 0
    var keyLabel = ""
    var command = false
    var option = false
    var control = false
    var shift = false

    var displayText: String {
        var value = ""
        if control { value += "⌃" }
        if option { value += "⌥" }
        if command { value += "⌘" }
        if shift { value += "⇧" }
        let renderedKey = keyLabel.count == 1 ? keyLabel.uppercased() : keyLabel
        return value + renderedKey
    }

    var isValid: Bool { !keyLabel.isEmpty }
}

struct KeyConfiguration: Codable, Identifiable, Equatable, Sendable {
    var id: MacroKey
    var actionKind: ActionKind = .none
    var applicationBookmark: Data?
    var applicationName = ""
    var shortcut = ShortcutDefinition()
    var urlString = ""
    var appleShortcutName = ""
    var executablePath = ""
    var arguments: [String] = []
    var commandTimeout: TimeInterval = 15
    var shellCommandEnabled = false
    var mediaAction: MediaAction = .playPause

    init(id: MacroKey) {
        self.id = id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(MacroKey.self, forKey: .id)
        actionKind = try container.decodeIfPresent(ActionKind.self, forKey: .actionKind) ?? .none
        applicationBookmark = try container.decodeIfPresent(Data.self, forKey: .applicationBookmark)
        applicationName = try container.decodeIfPresent(String.self, forKey: .applicationName) ?? ""
        shortcut = try container.decodeIfPresent(ShortcutDefinition.self, forKey: .shortcut) ?? ShortcutDefinition()
        urlString = try container.decodeIfPresent(String.self, forKey: .urlString) ?? ""
        appleShortcutName = try container.decodeIfPresent(String.self, forKey: .appleShortcutName) ?? ""
        executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath) ?? ""
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        commandTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .commandTimeout) ?? 15
        shellCommandEnabled = try container.decodeIfPresent(Bool.self, forKey: .shellCommandEnabled) ?? false
        mediaAction = try container.decodeIfPresent(MediaAction.self, forKey: .mediaAction) ?? .playPause
    }

    var displayName: String {
        switch actionKind {
        case .none: "Unassigned"
        case .launchApplication: applicationName.isEmpty ? "Choose Application" : applicationName
        case .keyboardShortcut: shortcut.isValid ? shortcut.displayText : "Record Shortcut"
        case .openURL: urlString.isEmpty ? "Enter URL" : urlString
        case .appleShortcut: appleShortcutName.isEmpty ? "Choose Shortcut" : appleShortcutName
        case .shellCommand: executablePath.isEmpty ? "Configure Command" : URL(fileURLWithPath: executablePath).lastPathComponent
        case .mediaControl: mediaAction.title
        }
    }
}

enum ProfileAssignmentMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case inheritDefault
    case override
    case disabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inheritDefault: "Inherit Default"
        case .override: "Override"
        case .disabled: "Disabled"
        }
    }
}

struct ProfileKeyAssignment: Codable, Identifiable, Equatable, Sendable {
    var id: MacroKey
    var mode: ProfileAssignmentMode = .inheritDefault
    var override: KeyConfiguration?
}

struct ApplicationProfile: Codable, Identifiable, Equatable, Sendable {
    var bundleIdentifier: String
    var displayName: String
    var applicationBookmark: Data?
    var assignments = MacroKey.allCases.map { ProfileKeyAssignment(id: $0) }

    var id: String { bundleIdentifier }

    init(bundleIdentifier: String, displayName: String, applicationBookmark: Data? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.applicationBookmark = applicationBookmark
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? bundleIdentifier
        applicationBookmark = try container.decodeIfPresent(Data.self, forKey: .applicationBookmark)
        assignments = try container.decodeIfPresent([ProfileKeyAssignment].self, forKey: .assignments) ?? []
        let existing = Set(assignments.map(\.id))
        assignments.append(contentsOf: MacroKey.allCases.filter { !existing.contains($0) }.map {
            ProfileKeyAssignment(id: $0)
        })
        assignments.sort { $0.id.rawValue < $1.id.rawValue }
    }
}

enum AssignmentOrigin: Equatable, Sendable {
    case defaultProfile
    case inherited
    case override
    case disabled
}

struct ResolvedKeyAssignment: Equatable, Sendable {
    let key: MacroKey
    let configuration: KeyConfiguration?
    let origin: AssignmentOrigin

    var canExecute: Bool {
        origin != .disabled && configuration?.isActionConfigured == true
    }
}

enum AssignmentResolver {
    static func resolve(
        key: MacroKey,
        foregroundBundleIdentifier: String?,
        configuration: AppConfiguration
    ) -> ResolvedKeyAssignment {
        let fallback = configuration.keys.first(where: { $0.id == key }) ?? KeyConfiguration(id: key)
        guard let foregroundBundleIdentifier,
              let profile = configuration.applicationProfiles.first(where: {
                  $0.bundleIdentifier == foregroundBundleIdentifier
              }),
              let assignment = profile.assignments.first(where: { $0.id == key }) else {
            return ResolvedKeyAssignment(key: key, configuration: fallback, origin: .defaultProfile)
        }

        switch assignment.mode {
        case .inheritDefault:
            return ResolvedKeyAssignment(key: key, configuration: fallback, origin: .inherited)
        case .override:
            let override = assignment.override ?? KeyConfiguration(id: key)
            return ResolvedKeyAssignment(key: key, configuration: override, origin: .override)
        case .disabled:
            return ResolvedKeyAssignment(key: key, configuration: nil, origin: .disabled)
        }
    }
}

struct AppConfiguration: Codable, Equatable, Sendable {
    static let currentVersion = 2

    var version = currentVersion
    var keys = MacroKey.allCases.map { KeyConfiguration(id: $0) }
    var selectedPeripheralID: UUID?
    var selectedPeripheralName: String?
    var automaticallyReconnect = true
    var showMenuBarItem = true
    var appearance = Appearance.system
    var applicationProfiles: [ApplicationProfile] = []

    enum Appearance: String, Codable, CaseIterable, Identifiable, Sendable {
        case system
        case light
        case dark
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        version = decodedVersion > Self.currentVersion ? decodedVersion : Self.currentVersion
        keys = try container.decodeIfPresent([KeyConfiguration].self, forKey: .keys) ?? []
        selectedPeripheralID = try container.decodeIfPresent(UUID.self, forKey: .selectedPeripheralID)
        selectedPeripheralName = try container.decodeIfPresent(String.self, forKey: .selectedPeripheralName)
        automaticallyReconnect = try container.decodeIfPresent(Bool.self, forKey: .automaticallyReconnect) ?? true
        showMenuBarItem = try container.decodeIfPresent(Bool.self, forKey: .showMenuBarItem) ?? true
        appearance = try container.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .system
        applicationProfiles = try container.decodeIfPresent(
            [ApplicationProfile].self,
            forKey: .applicationProfiles
        ) ?? []

        let existing = Set(keys.map(\.id))
        keys.append(contentsOf: MacroKey.allCases.filter { !existing.contains($0) }.map { KeyConfiguration(id: $0) })
        keys.sort { $0.id.rawValue < $1.id.rawValue }
        var seenBundleIdentifiers: Set<String> = []
        applicationProfiles = applicationProfiles.filter { profile in
            !profile.bundleIdentifier.isEmpty && seenBundleIdentifiers.insert(profile.bundleIdentifier).inserted
        }
    }
}

enum URLValidator {
    static func validatedHTTPURL(_ string: String) -> URL? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }
}

struct KeyStateMachine: Sendable {
    private(set) var pressedKeys: Set<MacroKey> = []
    private(set) var lastSequences: [MacroKey: UInt8] = [:]

    mutating func consume(_ event: ButtonEvent) -> Bool {
        if event.kind == .stateSync {
            set(event.key, pressed: event.transition == .pressed)
            lastSequences[event.key] = event.sequence
            return false
        }
        if lastSequences[event.key] == event.sequence {
            return false
        }
        lastSequences[event.key] = event.sequence

        switch event.transition {
        case .pressed:
            guard !pressedKeys.contains(event.key) else { return false }
            pressedKeys.insert(event.key)
            return true
        case .released:
            pressedKeys.remove(event.key)
            return false
        }
    }

    mutating func reset() {
        pressedKeys.removeAll()
        lastSequences.removeAll()
    }

    private mutating func set(_ key: MacroKey, pressed: Bool) {
        if pressed {
            pressedKeys.insert(key)
        } else {
            pressedKeys.remove(key)
        }
    }
}
