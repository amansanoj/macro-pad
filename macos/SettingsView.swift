import AppKit
import SwiftUI

struct MacroPadSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings(model: model)
            }
            Tab("Device", systemImage: "dot.radiowaves.left.and.right") {
                DeviceSettings(model: model)
            }
            Tab("Permissions", systemImage: "hand.raised") {
                PermissionSettings(model: model)
            }
            Tab("About", systemImage: "info.circle") {
                AboutSettings()
            }
        }
        .scenePadding()
        .frame(width: 500, height: 310)
    }
}

struct GeneralSettings: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Launch macro-pad at login",
                    isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )

                Picker(
                    "Appearance",
                    selection: Binding(
                        get: { model.configuration.appearance },
                        set: { model.configuration.appearance = $0 }
                    )
                ) {
                    ForEach(AppConfiguration.Appearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
            }

            Section {
                LabeledContent("Menu bar") {
                    Text("Always visible while running")
                        .foregroundStyle(.secondary)
                }

                Button("Open Configuration…") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct DeviceSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent(
                    "Device",
                    value: model.ble.discoveredDeviceName
                        ?? model.configuration.selectedPeripheralName
                        ?? "None selected"
                )
                LabeledContent("Status", value: model.ble.connectionState.title)

                Toggle(
                    "Reconnect automatically",
                    isOn: Binding(
                        get: { model.configuration.automaticallyReconnect },
                        set: { model.configuration.automaticallyReconnect = $0 }
                    )
                )
            }

            Section {
                HStack {
                    Button(connectionButtonTitle) {
                        model.connectOrDisconnect()
                    }

                    Button("Forget Device", role: .destructive) {
                        model.forgetDevice()
                    }
                    .disabled(
                        model.configuration.selectedPeripheralID == nil
                            && model.ble.selectedPeripheralID == nil
                    )
                }
            }
        }
        .formStyle(.grouped)
    }

    private var connectionButtonTitle: String {
        switch model.ble.connectionState {
        case .connected, .connecting: "Disconnect"
        case .scanning: "Stop"
        default: "Connect"
        }
    }
}

struct PermissionSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Accessibility") {
                    Label(
                        model.accessibilityGranted ? "Granted" : "Not granted",
                        systemImage: model.accessibilityGranted
                            ? "checkmark.circle.fill"
                            : "exclamationmark.circle"
                    )
                    .foregroundStyle(
                        model.accessibilityGranted ? Color.green : Color.secondary
                    )
                }

                Text(
                    "Accessibility is needed only for keyboard shortcut actions. Bluetooth permission is managed by macOS when device discovery begins."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            if !model.accessibilityGranted {
                Section {
                    Button("Open Accessibility Settings…") {
                        model.openAccessibilitySettings()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutSettings: View {
    var body: some View {
        Form {
            LabeledContent("Product", value: "macro-pad")
            LabeledContent(
                "Version",
                value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            )
            LabeledContent("Firmware protocol", value: "Version \(BLEProtocol.version)")
            Link(
                "github.com/amansanoj/macro-pad",
                destination: URL(string: "https://github.com/amansanoj/macro-pad")!
            )
        }
        .formStyle(.grouped)
    }
}
