import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        HSplitView {
            MacroPadPreview(model: model)
                .frame(minWidth: 420)
            KeyInspector(model: model)
                .frame(minWidth: 280, idealWidth: 310, maxWidth: 350)
        }
        .frame(minWidth: 740, minHeight: 300)
        .background(.background)
        .toolbar {
            ToolbarItem {
                Menu {
                    Label(model.ble.connectionState.title, systemImage: model.ble.connectionState.symbol)
                    Divider()
                    Button(
                        model.ble.connectionState == .connected ? "Disconnect" : "Connect"
                    ) {
                        model.connectOrDisconnect()
                    }
                } label: {
                    Label("Device", systemImage: "dot.radiowaves.left.and.right")
                        .labelStyle(.iconOnly)
                }
                .help("Device: \(model.ble.connectionState.title)")
                .accessibilityLabel("Device status and connection controls")
                .accessibilityValue(model.ble.connectionState.title)
            }

            ToolbarItem {
                Menu {
                    Toggle(
                        "Simulation Mode",
                        isOn: Binding(
                            get: { model.simulationMode },
                            set: { model.setSimulationMode($0) }
                        )
                    )
                } label: {
                    Label(
                        "Input",
                        systemImage: model.simulationMode
                            ? "keyboard.badge.exclamationmark"
                            : "keyboard"
                    )
                    .labelStyle(.iconOnly)
                }
                .help(model.simulationMode ? "Simulation mode is on" : "Input options")
                .accessibilityLabel("Input options")
                .accessibilityValue(model.simulationMode ? "Simulation mode on" : "Physical input")
            }
        }
    }
}

struct DeviceHeader: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            StatusIndicator(state: model.ble.connectionState)

            VStack(alignment: .leading, spacing: 1) {
                Text(deviceName)
                    .font(.headline)
                    .lineLimit(1)
                Text(model.ble.connectionState.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            if isTransient {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(model.ble.connectionState.title)
            }

            Button(connectionButtonTitle) {
                model.connectOrDisconnect()
            }
            .controlSize(.small)
            .help(connectionHelp)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(deviceName), \(model.ble.connectionState.title)")
        .help(model.ble.bluetoothMessage)
    }

    private var deviceName: String {
        model.ble.discoveredDeviceName
            ?? model.configuration.selectedPeripheralName
            ?? BLEProtocol.deviceName
    }

    private var isTransient: Bool {
        switch model.ble.connectionState {
        case .scanning, .connecting, .reconnecting: true
        default: false
        }
    }

    private var connectionButtonTitle: String {
        switch model.ble.connectionState {
        case .connected, .connecting: "Disconnect"
        case .scanning: "Stop"
        default: "Connect"
        }
    }

    private var connectionHelp: String {
        switch model.ble.connectionState {
        case .connected, .connecting: "Disconnect from macro-pad"
        case .scanning: "Stop looking for macro-pad"
        default: "Find and connect to macro-pad"
        }
    }
}

struct StatusIndicator: View {
    let state: ConnectionState

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(nsColor: .controlBackgroundColor))
            Image(systemName: state.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
                .font(.body.weight(.medium))
        }
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
    }

    private var color: Color {
        switch state {
        case .connected: .green
        case .failed: .red
        case .scanning, .connecting, .reconnecting: .accentColor
        case .disconnected: .secondary
        }
    }
}

struct MacroPadPreview: View {
    @Bindable var model: AppModel
    @State private var showDeleteProfileConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ProfileSelector(
                    model: model,
                    deleteProfile: {
                        if model.editingProfileHasCustomAssignments {
                            showDeleteProfileConfirmation = true
                        } else {
                            model.deleteEditingProfile()
                        }
                    }
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text("Keys")
                        .font(.title3.weight(.semibold))
                    Text("Select a key to configure its action.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    ForEach(model.editingAssignments, id: \.key) { assignment in
                        MacroKeyTile(
                            assignment: assignment,
                            isSelected: model.selectedKeyID == assignment.key,
                            isPressed: model.pressedKeys.contains(assignment.key),
                            simulationMode: model.simulationMode,
                            select: {
                                model.selectedKeyID = assignment.key
                                if model.simulationMode {
                                    model.simulatePress(assignment.key)
                                }
                            },
                            configure: { model.selectedKeyID = assignment.key },
                            test: { model.testAction(for: assignment.key) },
                            reset: { model.resetKey(assignment.key) }
                        )
                    }
                }

                if model.simulationMode {
                    Label(
                        "Simulation is on. Clicking a key runs its assigned action through the normal event pipeline.",
                        systemImage: "waveform.badge.exclamationmark"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Simulation mode is on")
                }

                if let report = model.executor.latestReport, !report.succeeded {
                    ExecutionStatus(report: report)
                }

                if let message = model.persistenceMessage {
                    InlineNotice(
                        symbol: "exclamationmark.triangle.fill",
                        title: "Configuration issue",
                        detail: message,
                        isError: true
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(16)
        }
        .confirmationDialog(
            "Delete \(model.editingProfileName) profile?",
            isPresented: $showDeleteProfileConfirmation
        ) {
            Button("Delete Profile", role: .destructive) {
                model.deleteEditingProfile()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its application-specific overrides will be removed. Default and other profiles are unchanged.")
        }
    }
}

struct ProfileSelector: View {
    @Bindable var model: AppModel
    let deleteProfile: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    model.editingProfileID = nil
                } label: {
                    Label("Default", systemImage: "square.grid.2x2")
                }

                if !model.configuration.applicationProfiles.isEmpty {
                    Divider()
                    ForEach(model.configuration.applicationProfiles) { profile in
                        Button {
                            model.editingProfileID = profile.bundleIdentifier
                        } label: {
                            if let image = ProfileApplicationIconCache.shared.icon(for: profile) {
                                Label {
                                    Text(profile.displayName)
                                } icon: {
                                    Image(nsImage: image)
                                }
                            } else {
                                Label(profile.displayName, systemImage: "app.dashed")
                            }
                        }
                    }
                }

                Divider()
                Button("Add Application…", systemImage: "plus") {
                    model.addApplicationProfile()
                }
            } label: {
                HStack(spacing: 7) {
                    ProfileIcon(profile: model.editingProfile, size: 22)
                    Text(model.editingProfileName)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Editing profile")
            .accessibilityValue(model.editingProfileName)

            if model.editingProfile != nil {
                Button("Delete Profile", systemImage: "trash", action: deleteProfile)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Delete \(model.editingProfileName) profile")
            }

            Spacer()

            Text("Editing")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct ProfileIcon: View {
    let profile: ApplicationProfile?
    let size: CGFloat

    var body: some View {
        Group {
            if let profile, let image = ProfileApplicationIconCache.shared.icon(for: profile) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: profile == nil ? "square.grid.2x2" : "app.dashed")
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .padding(2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct MacroKeyTile: View {
    let assignment: ResolvedKeyAssignment
    let isSelected: Bool
    let isPressed: Bool
    let simulationMode: Bool
    let select: () -> Void
    let configure: () -> Void
    let test: () -> Void
    let reset: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title2) private var iconSize = 38

    private var presentation: ActionPresentation {
        ActionPresentation(configuration: configuration)
    }

    private var configuration: KeyConfiguration {
        assignment.configuration ?? KeyConfiguration(id: assignment.key)
    }

    var body: some View {
        Button(action: select) {
            MacroKeyTileContent(
                configuration: configuration,
                presentation: presentation,
                origin: assignment.origin,
                isSelected: isSelected,
                isPressed: isPressed,
                iconSize: iconSize,
                background: tileBackground,
                border: borderColor
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isPressed)
        .help(presentation.tooltip)
        .contextMenu {
            Button("Configure") { configure() }
            Button("Test Action", systemImage: "play.fill") { test() }
                .disabled(!assignment.canExecute)
            Divider()
            Button("Reset Key", systemImage: "arrow.counterclockwise") { reset() }
                .disabled(assignment.origin == .inherited || assignment.origin == .disabled || configuration.actionKind == .none)
        }
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint(simulationMode ? "Selects and simulates this key." : "Selects this key for configuration.")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var tileBackground: Color {
        if isPressed { return Color.accentColor.opacity(0.16) }
        if isSelected { return Color.accentColor.opacity(0.09) }
        if isHovering { return Color(nsColor: .selectedContentBackgroundColor).opacity(0.08) }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var borderColor: Color {
        if isSelected { return .accentColor }
        if isHovering { return Color(nsColor: .separatorColor).opacity(0.9) }
        return Color(nsColor: .separatorColor)
    }

    private var accessibilityDescription: String {
        var parts = [
            configuration.id.title,
            assignment.origin == .disabled ? "Disabled" : presentation.title,
            configuration.actionKind.title
        ]
        if assignment.origin == .inherited { parts.append("inherited from Default") }
        if assignment.origin == .disabled { parts.append("disabled for \(configuration.id.title)") }
        if isSelected { parts.append("selected") }
        if isPressed { parts.append("pressed") }
        return parts.joined(separator: ", ")
    }
}

struct MacroKeyTileContent: View {
    let configuration: KeyConfiguration
    let presentation: ActionPresentation
    let origin: AssignmentOrigin
    let isSelected: Bool
    let isPressed: Bool
    let iconSize: CGFloat
    let background: Color
    let border: Color

    var body: some View {
        VStack(spacing: 9) {
            HStack {
                Text(configuration.id.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if isPressed {
                    Label("Pressed", systemImage: "arrow.down.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Color.accentColor)
                        .help("Physical key is pressed")
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                } else if origin == .inherited {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Inherited from Default")
                        .accessibilityHidden(true)
                } else if origin == .disabled {
                    Image(systemName: "nosign")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }

            if origin == .disabled {
                Image(systemName: "nosign")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .frame(width: iconSize, height: iconSize)
                    .accessibilityHidden(true)
            } else {
                ActionIcon(configuration: configuration, size: iconSize)
            }

            Text(origin == .disabled ? "Disabled" : presentation.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .allowsTightening(true)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 112)
        .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(border, lineWidth: isSelected ? 1.5 : 1)
        }
        .contentShape(.rect)
        .offset(y: isPressed ? 2 : 0)
        .scaleEffect(isPressed ? 0.985 : 1)
    }
}

struct ActionIcon: View {
    let configuration: KeyConfiguration
    let size: CGFloat

    var body: some View {
        Group {
            if let image = ApplicationIconCache.shared.icon(for: configuration) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: ActionPresentation(configuration: configuration).symbolName)
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(iconColor)
                    .padding(5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var iconColor: Color {
        configuration.actionKind == .none ? .secondary : .accentColor
    }
}

struct ExecutionStatus: View {
    let report: ExecutionReport

    var body: some View {
        InlineNotice(
            symbol: report.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            title: report.summary,
            detail: report.details,
            isError: !report.succeeded
        )
        .accessibilityLabel(
            "\(report.succeeded ? "Action succeeded" : "Action failed"), \(report.summary), \(report.details)"
        )
    }
}

struct InlineNotice: View {
    let symbol: String
    let title: String
    let detail: String
    let isError: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(isError ? Color.red : Color.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct KeyInspector: View {
    @Bindable var model: AppModel
    @State private var showCommandWarning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                InspectorHeader(assignment: model.selectedResolvedAssignment)

                if model.editingProfile != nil {
                    InspectorSection("Assignment") {
                        Picker("Assignment", selection: assignmentModeBinding) {
                            ForEach(ProfileAssignmentMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .accessibilityLabel("Assignment behavior")
                    }
                }

                if model.selectedResolvedAssignment.origin == .disabled {
                    Label(
                        "This key does nothing while \(model.editingProfileName) is active.",
                        systemImage: "nosign"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } else if model.selectedResolvedAssignment.origin == .inherited {
                    Label(
                        "Uses the current Default assignment. Changes to Default apply automatically.",
                        systemImage: "arrow.triangle.branch"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Button("Create Override") {
                        model.setSelectedAssignmentMode(.override)
                    }
                    .controlSize(.small)
                } else {
                    InspectorSection("Action") {
                        ActionPicker(selection: actionKindBinding)
                    }

                    ActionConfigurationFields(model: model)

                    if model.editingProfile != nil {
                        Button("Use Default Assignment") {
                            model.setSelectedAssignmentMode(.inheritDefault)
                        }
                        .controlSize(.small)
                    }
                }

                Divider()

                HStack {
                    Button("Test Action", systemImage: "play.fill") {
                        model.testAction(for: model.selectedKeyID)
                    }
                    .disabled(!model.selectedResolvedAssignment.canExecute)

                    Spacer()

                    Button("Reset Key", systemImage: "arrow.counterclockwise") {
                        model.resetSelectedKey()
                    }
                    .disabled(
                        model.selectedResolvedAssignment.origin == .inherited
                            || model.selectedResolvedAssignment.origin == .disabled
                            || model.selectedConfiguration.actionKind == .none
                    )
                }
                .controlSize(.small)
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Shell commands can access local data", isPresented: $showCommandWarning) {
            Button("Enable") {
                model.updateSelected { $0.shellCommandEnabled = true }
            }
            Button("Cancel", role: .cancel) {
                model.updateSelected { $0.actionKind = .none }
            }
        } message: {
            Text("Only configure executables and arguments you trust. macro-pad never accepts commands over Bluetooth and never requests elevated privileges.")
        }
    }

    private var actionKindBinding: Binding<ActionKind> {
        Binding(
            get: { model.selectedConfiguration.actionKind },
            set: { newValue in
                model.updateSelected { $0.actionKind = newValue }
                if newValue == .shellCommand && !model.selectedConfiguration.shellCommandEnabled {
                    showCommandWarning = true
                }
            }
        )
    }

    private var assignmentModeBinding: Binding<ProfileAssignmentMode> {
        Binding(
            get: { model.selectedAssignmentMode ?? .inheritDefault },
            set: { model.setSelectedAssignmentMode($0) }
        )
    }
}

struct InspectorHeader: View {
    let assignment: ResolvedKeyAssignment
    @ScaledMetric(relativeTo: .title3) private var iconSize = 40

    private var configuration: KeyConfiguration {
        assignment.configuration ?? KeyConfiguration(id: assignment.key)
    }

    var body: some View {
        HStack(spacing: 12) {
            if assignment.origin == .disabled {
                Image(systemName: "nosign")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .frame(width: iconSize, height: iconSize)
                    .accessibilityHidden(true)
            } else {
                ActionIcon(configuration: configuration, size: iconSize)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(configuration.id.title)
                    .font(.title3.weight(.semibold))
                Text(assignment.origin == .disabled ? "Disabled" : ActionPresentation(configuration: configuration).title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            accessibilityDescription
        )
    }

    private var accessibilityDescription: String {
        var parts = [configuration.id.title]
        if assignment.origin == .disabled {
            parts.append("disabled")
        } else {
            parts.append(configuration.actionKind.title)
            parts.append(ActionPresentation(configuration: configuration).title)
        }
        if assignment.origin == .inherited { parts.append("inherited from Default") }
        return parts.joined(separator: ", ")
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
    }
}

struct ActionPicker: View {
    @Binding var selection: ActionKind

    var body: some View {
        Menu {
            Section("Applications and Navigation") {
                actionButton(.launchApplication)
                actionButton(.openURL)
            }
            Section("Keyboard and Automation") {
                actionButton(.keyboardShortcut)
                actionButton(.appleShortcut)
                actionButton(.shellCommand)
            }
            Section("System") {
                actionButton(.none)
            }
        } label: {
            HStack {
                Label(selection.title, systemImage: selection.symbol)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Action type")
        .accessibilityValue(selection.title)
    }

    private func actionButton(_ kind: ActionKind) -> some View {
        Button {
            selection = kind
        } label: {
            Label(kind.title, systemImage: kind.symbol)
        }
    }
}

struct ActionConfigurationFields: View {
    @Bindable var model: AppModel

    var body: some View {
        switch model.selectedConfiguration.actionKind {
        case .none:
            UnassignedInspector()
        case .launchApplication:
            ApplicationInspector(model: model)
        case .keyboardShortcut:
            ShortcutInspector(model: model)
        case .openURL:
            URLInspector(model: model)
        case .appleShortcut:
            AppleShortcutInspector(model: model)
        case .shellCommand:
            ShellCommandInspector(model: model)
        case .mediaControl:
            MediaInspector()
        }
    }
}

struct UnassignedInspector: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
            Text("This key will not run an action.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct ApplicationInspector: View {
    @Bindable var model: AppModel
    @ScaledMetric(relativeTo: .body) private var iconSize = 42

    var body: some View {
        InspectorSection("Application") {
            HStack(spacing: 10) {
                ActionIcon(configuration: model.selectedConfiguration, size: iconSize)
                VStack(alignment: .leading, spacing: 2) {
                    Text(applicationName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(applicationDetail)
                        .font(.caption)
                        .foregroundStyle(isMissing ? Color.red : Color.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button(model.selectedConfiguration.applicationName.isEmpty ? "Choose…" : "Change…") {
                    model.chooseApplication()
                }
                .controlSize(.small)
            }
        }
    }

    private var applicationName: String {
        model.selectedConfiguration.applicationName.isEmpty
            ? "No application selected"
            : model.selectedConfiguration.applicationName
    }

    private var isMissing: Bool {
        ApplicationIconCache.shared.isMissing(model.selectedConfiguration)
    }

    private var applicationDetail: String {
        if isMissing { return "Application cannot be located. Choose a replacement." }
        return ApplicationIconCache.shared.applicationURL(for: model.selectedConfiguration)?.path
            ?? "Choose an application bundle."
    }
}

struct ShortcutInspector: View {
    @Bindable var model: AppModel
    @State private var recorderError: String?

    var body: some View {
        InspectorSection("Keyboard Shortcut") {
            HStack(spacing: 8) {
                ShortcutRecorder(shortcut: shortcutBinding) { error in
                    recorderError = error
                }
                    .frame(minHeight: 30)
                Button("Clear") {
                    model.updateSelected { $0.shortcut = ShortcutDefinition() }
                }
                .controlSize(.small)
                .disabled(!model.selectedConfiguration.shortcut.isValid)
            }

            if let recorderError,
               model.accessibilityGranted || !recorderError.hasPrefix("Accessibility permission") {
                Label(recorderError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            DisclosureGroup("Enter shortcut manually") {
                ManualShortcutEditor(shortcut: shortcutBinding)
                    .padding(.top, 6)
            }
            .font(.caption)

            if !model.accessibilityGranted {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(
                        "Accessibility permission is required.",
                        systemImage: "hand.raised.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button("Open Settings…") {
                        model.openAccessibilitySettings()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var shortcutBinding: Binding<ShortcutDefinition> {
        Binding(
            get: { model.selectedConfiguration.shortcut },
            set: { value in model.updateSelected { $0.shortcut = value } }
        )
    }
}

struct URLInspector: View {
    @Bindable var model: AppModel

    var body: some View {
        InspectorSection("URL") {
            TextField("https://example.com", text: stringBinding)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Destination URL")

            if !model.selectedConfiguration.urlString.isEmpty {
                if URLValidator.validatedHTTPURL(model.selectedConfiguration.urlString) == nil {
                    Label("Enter a complete HTTP or HTTPS URL.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("Preview: \(ActionPresentation.readableHost(model.selectedConfiguration.urlString))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var stringBinding: Binding<String> {
        Binding(
            get: { model.selectedConfiguration.urlString },
            set: { value in model.updateSelected { $0.urlString = value } }
        )
    }
}

struct AppleShortcutInspector: View {
    @Bindable var model: AppModel

    var body: some View {
        InspectorSection("Apple Shortcut") {
            TextField("Shortcut name", text: stringBinding)
                .textFieldStyle(.roundedBorder)
            Text("The name must match an installed shortcut. Execution uses the system shortcuts command.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var stringBinding: Binding<String> {
        Binding(
            get: { model.selectedConfiguration.appleShortcutName },
            set: { value in model.updateSelected { $0.appleShortcutName = value } }
        )
    }
}

struct ShellCommandInspector: View {
    @Bindable var model: AppModel

    var body: some View {
        InspectorSection("Command") {
            TextField("/usr/bin/open", text: executableBinding)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Executable path")

            TextField("Arguments, one per line", text: argumentsBinding, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .accessibilityLabel("Command arguments")

            Stepper(
                "Timeout: \(Int(model.selectedConfiguration.commandTimeout)) seconds",
                value: timeoutBinding,
                in: 1...300
            )

            Toggle("Command execution enabled", isOn: enabledBinding)

            Label(
                "Commands run directly without a shell or elevated privileges.",
                systemImage: "exclamationmark.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var executableBinding: Binding<String> {
        Binding(
            get: { model.selectedConfiguration.executablePath },
            set: { value in model.updateSelected { $0.executablePath = value } }
        )
    }

    private var argumentsBinding: Binding<String> {
        Binding(
            get: { model.selectedConfiguration.arguments.joined(separator: "\n") },
            set: { value in
                model.updateSelected {
                    $0.arguments = value.split(
                        separator: "\n",
                        omittingEmptySubsequences: false
                    ).map(String.init)
                }
            }
        )
    }

    private var timeoutBinding: Binding<Int> {
        Binding(
            get: { Int(model.selectedConfiguration.commandTimeout) },
            set: { value in model.updateSelected { $0.commandTimeout = TimeInterval(value) } }
        )
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { model.selectedConfiguration.shellCommandEnabled },
            set: { value in model.updateSelected { $0.shellCommandEnabled = value } }
        )
    }
}

struct MediaInspector: View {
    var body: some View {
        InspectorSection("Media Control") {
            Label(
                "This saved assignment is preserved, but system-wide media controls are not available through public macOS APIs. Choose Apple Shortcut for supported automation.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

#if DEBUG
#Preview("Configuration Dark") {
    ContentView(model: PreviewFixtures.model())
        .frame(width: 820, height: 340)
        .preferredColorScheme(.dark)
        .allowsHitTesting(false)
}

#Preview("Application Profiles Light") {
    ContentView(model: PreviewFixtures.model(profile: true))
        .frame(width: 820, height: 340)
        .preferredColorScheme(.light)
        .allowsHitTesting(false)
}
#endif
