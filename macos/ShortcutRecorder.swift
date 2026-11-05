import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

struct ShortcutRecorderDependencies {
    var isAccessibilityTrusted: () -> Bool
    var createEventTap: (CGEventMask, CGEventTapCallBack, UnsafeMutableRawPointer) -> CFMachPort?

    init(
        isAccessibilityTrusted: @escaping () -> Bool,
        createEventTap: @escaping (CGEventMask, CGEventTapCallBack, UnsafeMutableRawPointer) -> CFMachPort?
    ) {
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.createEventTap = createEventTap
    }

    static let live = ShortcutRecorderDependencies(
        isAccessibilityTrusted: { AXIsProcessTrusted() },
        createEventTap: { mask, callback, userInfo in
            CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: userInfo
            )
        }
    )
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: ShortcutDefinition
    let onFailure: (String?) -> Void

    init(shortcut: Binding<ShortcutDefinition>, onFailure: @escaping (String?) -> Void) {
        _shortcut = shortcut
        self.onFailure = onFailure
    }

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.onChange = { shortcut = $0 }
        view.onFailure = onFailure
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        nsView.shortcut = shortcut
        nsView.onFailure = onFailure
        nsView.updateAccessibility()
        nsView.needsDisplay = true
    }

    static func dismantleNSView(_ nsView: ShortcutRecorderView, coordinator: ()) {
        nsView.stopRecording()
    }
}

@MainActor
final class ShortcutRecorderView: NSView {
    var shortcut = ShortcutDefinition()
    var onChange: ((ShortcutDefinition) -> Void)?
    var onFailure: ((String?) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var capturedKeyCode: UInt16?
    private(set) var isRecording = false
    private let dependencies: ShortcutRecorderDependencies

    override init(frame frameRect: NSRect) {
        dependencies = .live
        super.init(frame: frameRect)
        configureAccessibility()
        observeApplicationLifecycle()
    }

    init(dependencies: ShortcutRecorderDependencies) {
        self.dependencies = dependencies
        super.init(frame: .zero)
        configureAccessibility()
        observeApplicationLifecycle()
    }

    required init?(coder: NSCoder) {
        dependencies = .live
        super.init(coder: coder)
        configureAccessibility()
        observeApplicationLifecycle()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        guard startRecording() else { return false }
        let accepted = super.becomeFirstResponder()
        if !accepted { stopRecording() }
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        let accepted = super.resignFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        // An active event tap handles recording. Never fall back to local
        // capture because system shortcuts would no longer be suppressed.
    }

    func startRecording() -> Bool {
        guard !isRecording else { return true }
        guard dependencies.isAccessibilityTrusted() else {
            reportFailure("Accessibility permission is required to safely record shortcuts.")
            return false
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = dependencies.createEventTap(mask, shortcutRecorderEventCallback, userInfo) else {
            reportFailure("Protected recording could not start. Check Accessibility permission or enter the shortcut manually.")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        capturedKeyCode = nil
        isRecording = true
        onFailure?(nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        updateAccessibility()
        needsDisplay = true
        return true
    }

    func stopRecording() {
        guard isRecording || eventTap != nil || runLoopSource != nil else { return }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        capturedKeyCode = nil
        isRecording = false
        updateAccessibility()
        needsDisplay = true
    }

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard isRecording else { return Unmanaged.passUnretained(event) }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stopRecording()
            reportFailure("Protected recording stopped because macOS disabled the keyboard event tap.")
            window?.makeFirstResponder(nil)
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .flagsChanged:
            return nil
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

            if keyCode == 53 {
                stopAndReleaseFocus()
                return nil
            }
            if keyCode == 51 || keyCode == 117 {
                shortcut = ShortcutDefinition()
                onChange?(shortcut)
                stopAndReleaseFocus()
                return nil
            }

            guard capturedKeyCode == nil,
                  let definition = ShortcutKeyCatalog.definition(for: event) else {
                return nil
            }
            capturedKeyCode = definition.keyCode
            shortcut = definition
            onChange?(definition)
            updateAccessibility()
            needsDisplay = true
            return nil
        case .keyUp:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == capturedKeyCode {
                stopAndReleaseFocus()
            }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let drawingBounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: drawingBounds, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let value: String
        if isRecording && capturedKeyCode == nil {
            value = "Type shortcut…"
        } else {
            value = shortcut.isValid ? shortcut.displayText : "Click and type shortcut"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.preferredFont(forTextStyle: .body),
            .foregroundColor: shortcut.isValid || isRecording ? NSColor.labelColor : NSColor.secondaryLabelColor
        ]
        let size = value.size(withAttributes: attributes)
        value.draw(
            at: NSPoint(
                x: max(6, (drawingBounds.width - size.width) / 2),
                y: (drawingBounds.height - size.height) / 2
            ),
            withAttributes: attributes
        )
    }

    func updateAccessibility() {
        if isRecording {
            setAccessibilityValue(capturedKeyCode == nil ? "Recording" : shortcut.displayText)
        } else {
            setAccessibilityValue(shortcut.isValid ? shortcut.displayText : "No shortcut recorded")
        }
    }

    @objc private func applicationDidResignActive() {
        stopAndReleaseFocus()
    }

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Keyboard shortcut recorder")
        setAccessibilityHelp("Click, then press a shortcut. Escape cancels and Delete clears.")
        updateAccessibility()
    }

    private func observeApplicationLifecycle() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    private func stopAndReleaseFocus() {
        stopRecording()
        window?.makeFirstResponder(nil)
    }

    private func reportFailure(_ message: String) {
        onFailure?(message)
        updateAccessibility()
        needsDisplay = true
    }
}

private let shortcutRecorderEventCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let recorder = Unmanaged<ShortcutRecorderView>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated {
        recorder.handleEvent(type: type, event: event)
    }
}

struct ManualShortcutEditor: View {
    @Binding var shortcut: ShortcutDefinition

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle("⌃", isOn: modifierBinding(\.control))
                    .accessibilityLabel("Control")
                Toggle("⌥", isOn: modifierBinding(\.option))
                    .accessibilityLabel("Option")
                Toggle("⇧", isOn: modifierBinding(\.shift))
                    .accessibilityLabel("Shift")
                Toggle("⌘", isOn: modifierBinding(\.command))
                    .accessibilityLabel("Command")
            }
            .toggleStyle(.checkbox)
            .accessibilityElement(children: .contain)

            Picker("Key", selection: keyCodeBinding) {
                Text("Choose Key").tag(UInt16.max)
                ForEach(ShortcutKeyCatalog.manualKeys) { key in
                    Text(key.label).tag(key.keyCode)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var keyCodeBinding: Binding<UInt16> {
        Binding(
            get: { shortcut.isValid ? shortcut.keyCode : UInt16.max },
            set: { keyCode in
                guard let key = ShortcutKeyCatalog.manualKeys.first(where: { $0.keyCode == keyCode }) else {
                    shortcut.keyCode = 0
                    shortcut.keyLabel = ""
                    return
                }
                shortcut.keyCode = key.keyCode
                shortcut.keyLabel = key.label
            }
        )
    }

    private func modifierBinding(_ keyPath: WritableKeyPath<ShortcutDefinition, Bool>) -> Binding<Bool> {
        Binding(
            get: { shortcut[keyPath: keyPath] },
            set: { shortcut[keyPath: keyPath] = $0 }
        )
    }
}

struct ManualShortcutKey: Identifiable, Equatable, Sendable {
    let keyCode: UInt16
    let label: String
    var id: UInt16 { keyCode }
}

enum ShortcutKeyCatalog {
    static let manualKeys: [ManualShortcutKey] = [
        .init(keyCode: 0, label: "A"), .init(keyCode: 11, label: "B"),
        .init(keyCode: 8, label: "C"), .init(keyCode: 2, label: "D"),
        .init(keyCode: 14, label: "E"), .init(keyCode: 3, label: "F"),
        .init(keyCode: 5, label: "G"), .init(keyCode: 4, label: "H"),
        .init(keyCode: 34, label: "I"), .init(keyCode: 38, label: "J"),
        .init(keyCode: 40, label: "K"), .init(keyCode: 37, label: "L"),
        .init(keyCode: 46, label: "M"), .init(keyCode: 45, label: "N"),
        .init(keyCode: 31, label: "O"), .init(keyCode: 35, label: "P"),
        .init(keyCode: 12, label: "Q"), .init(keyCode: 15, label: "R"),
        .init(keyCode: 1, label: "S"), .init(keyCode: 17, label: "T"),
        .init(keyCode: 32, label: "U"), .init(keyCode: 9, label: "V"),
        .init(keyCode: 13, label: "W"), .init(keyCode: 7, label: "X"),
        .init(keyCode: 16, label: "Y"), .init(keyCode: 6, label: "Z"),
        .init(keyCode: 29, label: "0"), .init(keyCode: 18, label: "1"),
        .init(keyCode: 19, label: "2"), .init(keyCode: 20, label: "3"),
        .init(keyCode: 21, label: "4"), .init(keyCode: 23, label: "5"),
        .init(keyCode: 22, label: "6"), .init(keyCode: 26, label: "7"),
        .init(keyCode: 28, label: "8"), .init(keyCode: 25, label: "9"),
        .init(keyCode: 49, label: "Space"), .init(keyCode: 48, label: "⇥"),
        .init(keyCode: 36, label: "↩"), .init(keyCode: 123, label: "←"),
        .init(keyCode: 124, label: "→"), .init(keyCode: 125, label: "↓"),
        .init(keyCode: 126, label: "↑")
    ]

    static func definition(for event: CGEvent) -> ShortcutDefinition? {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let label = manualKeys.first(where: { $0.keyCode == keyCode })?.label
            ?? NSEvent(cgEvent: event)?.charactersIgnoringModifiers
            ?? ""
        guard !label.isEmpty else { return nil }
        let flags = event.flags
        return ShortcutDefinition(
            keyCode: keyCode,
            keyLabel: label,
            command: flags.contains(.maskCommand),
            option: flags.contains(.maskAlternate),
            control: flags.contains(.maskControl),
            shift: flags.contains(.maskShift)
        )
    }
}
