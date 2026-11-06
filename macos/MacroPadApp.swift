import AppKit
import SwiftUI

@main
struct MacroPadApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover(model: model)
                .preferredColorScheme(preferredColorScheme)
        } label: {
            Label(
                "macro-pad, \(model.ble.connectionState.title)",
                systemImage: menuBarSymbol
            )
            .labelStyle(.iconOnly)
            .accessibilityLabel("macro-pad, \(model.ble.connectionState.title)")
        }
        .menuBarExtraStyle(.window)

        Window("macro-pad", id: "main") {
            ContentView(model: model)
                .preferredColorScheme(preferredColorScheme)
        }
        .defaultSize(width: 820, height: 340)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            MacroPadSettingsView(model: model)
                .preferredColorScheme(preferredColorScheme)
        }
    }

    private var menuBarSymbol: String {
        switch model.ble.connectionState {
        case .connected:
            "keyboard.badge.ellipsis.fill"
        case .failed:
            "keyboard.badge.ellipsis"
        default:
            "keyboard.badge.ellipsis"
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch model.configuration.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct MenuBarPopover: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            MenuBarDeviceHeader(model: model)

            Divider()

            MenuBarKeyOverview(
                assignments: model.executionAssignments,
                pressedKeys: model.pressedKeys,
                selectKey: openConfiguration(for:)
            )

            if let report = model.executor.latestReport, !report.succeeded {
                Divider()
                MenuBarFailure(report: report)
            }

            Divider()

            MenuBarActions(
                openConfiguration: { openConfiguration(for: nil) },
                openSettings: showSettings,
                quit: { NSApp.terminate(nil) }
            )
        }
        .frame(width: 340)
    }

    private func openConfiguration(for key: MacroKey?) {
        if let key {
            model.selectedKeyID = key
            model.editingProfileID = model.activeExecutionProfile?.bundleIdentifier
        }
        dismiss()
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showSettings() {
        dismiss()
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MenuBarDeviceHeader: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            StatusIndicator(state: model.ble.connectionState)

            VStack(alignment: .leading, spacing: 1) {
                Text("macro-pad")
                    .font(.headline)
                Text(statusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isTransient {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(model.ble.connectionState.title)
            }

            Button(connectionButtonTitle) {
                model.connectOrDisconnect()
            }
            .controlSize(.small)
        }
        .padding(14)
        .accessibilityElement(children: .contain)
    }

    private var statusDescription: String {
        let device = model.ble.discoveredDeviceName
            ?? model.configuration.selectedPeripheralName
            ?? BLEProtocol.deviceName

        switch model.ble.connectionState {
        case .connected:
            let connection = device.caseInsensitiveCompare(BLEProtocol.deviceName) == .orderedSame
                ? "Connected"
                : "\(device) · Connected"
            return "\(connection) · \(model.activeExecutionProfileName)"
        case .failed(let message):
            return "Connection failed · \(message)"
        default:
            return model.ble.connectionState.title
        }
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
}

struct MenuBarKeyOverview: View {
    let assignments: [ResolvedKeyAssignment]
    let pressedKeys: Set<MacroKey>
    let selectKey: (MacroKey) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Keys")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                ForEach(assignments, id: \.key) { assignment in
                    MenuBarKeyButton(
                        assignment: assignment,
                        isPressed: pressedKeys.contains(assignment.key),
                        action: { selectKey(assignment.key) }
                    )
                }
            }
        }
        .padding(14)
    }
}

struct MenuBarKeyButton: View {
    let assignment: ResolvedKeyAssignment
    let isPressed: Bool
    let action: () -> Void

    @State private var isHovering = false
    @ScaledMetric(relativeTo: .body) private var iconSize = 28

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                HStack {
                    Text(String(assignment.key.rawValue))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isPressed {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                    }
                }

                if let configuration = assignment.configuration {
                    ActionIcon(configuration: configuration, size: iconSize)
                } else {
                    Image(systemName: "nosign")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .padding(5)
                        .frame(width: iconSize, height: iconSize)
                        .accessibilityHidden(true)
                }

                Text(displayTitle)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.78)
                    .allowsTightening(true)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(
                isPressed
                    ? Color.accentColor.opacity(0.14)
                    : isHovering
                        ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.08)
                        : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Configure \(assignment.key.title): \(tooltip)")
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Opens this key in the configuration window.")
    }

    private var accessibilityDescription: String {
        var parts = [assignment.key.title, displayTitle]
        if assignment.origin == .inherited { parts.append("inherited from Default") }
        if assignment.origin == .disabled { parts.append("disabled") }
        if isPressed { parts.append("pressed") }
        return parts.joined(separator: ", ")
    }

    private var displayTitle: String {
        guard let configuration = assignment.configuration else { return "Disabled" }
        return ActionPresentation(configuration: configuration).title
    }

    private var tooltip: String {
        guard let configuration = assignment.configuration else { return "Disabled for this application" }
        let suffix = assignment.origin == .inherited ? " · Inherited from Default" : ""
        return ActionPresentation(configuration: configuration).tooltip + suffix
    }
}

struct MenuBarFailure: View {
    let report: ExecutionReport

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(report.summary)
                    .font(.caption.weight(.medium))
                Text(report.details)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Action failed, \(report.summary), \(report.details)")
    }
}

struct MenuBarActions: View {
    let openConfiguration: () -> Void
    let openSettings: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            MenuBarActionButton(
                title: "Open Configuration",
                symbol: "slider.horizontal.3",
                action: openConfiguration
            )
            MenuBarActionButton(
                title: "Settings…",
                symbol: "gearshape",
                action: openSettings
            )
            Divider()
                .padding(.vertical, 3)
            MenuBarActionButton(
                title: "Quit macro-pad",
                symbol: "power",
                action: quit
            )
        }
        .padding(6)
    }
}

#if DEBUG
#Preview("Menu Bar Popover Dark") {
    MenuBarPopover(model: PreviewFixtures.model())
        .preferredColorScheme(.dark)
        .allowsHitTesting(false)
}
#endif

struct MenuBarActionButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
                    .frame(width: 16)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            isHovering ? Color.primary.opacity(0.06) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .onHover { isHovering = $0 }
    }
}
