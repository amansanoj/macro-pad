import AppKit
import ApplicationServices
import Foundation
import Observation

struct ExecutionReport: Identifiable, Equatable {
    let id = UUID()
    let key: MacroKey
    let succeeded: Bool
    let summary: String
    let details: String
    let date = Date()
}

struct ProcessResult: Equatable, Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String
    let timedOut: Bool
}

enum ActionExecutionError: LocalizedError {
    case inaccessibleApplication
    case invalidShortcut
    case accessibilityRequired
    case invalidURL
    case commandDisabled
    case invalidExecutable
    case timedOut
    case processFailure(Int32, String)
    case unsupportedMediaAction

    var errorDescription: String? {
        switch self {
        case .inaccessibleApplication: "The selected application is unavailable. Choose it again."
        case .invalidShortcut: "Record a valid keyboard shortcut first."
        case .accessibilityRequired: "Keyboard shortcuts require Accessibility permission."
        case .invalidURL: "Enter a valid HTTP or HTTPS URL."
        case .commandDisabled: "Confirm the shell-command warning before using this action."
        case .invalidExecutable: "Choose an absolute executable path. Commands are not interpreted by a shell."
        case .timedOut: "The command exceeded its configured timeout and was terminated."
        case .processFailure(let status, let error): "The process exited with status \(status). \(error)"
        case .unsupportedMediaAction:
            "macOS does not provide a public system-wide media-control API for this action. Configure an Apple Shortcut as a workaround."
        }
    }
}

@MainActor
@Observable
final class ActionExecutor {
    private(set) var latestReport: ExecutionReport?
    private(set) var commandIsRunning = false

    func execute(_ configuration: KeyConfiguration) {
        Task {
            do {
                let details = try await perform(configuration)
                latestReport = ExecutionReport(
                    key: configuration.id,
                    succeeded: true,
                    summary: "\(configuration.displayName) completed",
                    details: details
                )
            } catch {
                latestReport = ExecutionReport(
                    key: configuration.id,
                    succeeded: false,
                    summary: "\(configuration.displayName) failed",
                    details: error.localizedDescription
                )
            }
        }
    }

    private func perform(_ configuration: KeyConfiguration) async throws -> String {
        switch configuration.actionKind {
        case .none:
            return "No action is assigned."
        case .launchApplication:
            return try await launchApplication(configuration)
        case .keyboardShortcut:
            return try postShortcut(configuration.shortcut)
        case .openURL:
            guard let url = URLValidator.validatedHTTPURL(configuration.urlString) else {
                throw ActionExecutionError.invalidURL
            }
            guard NSWorkspace.shared.open(url) else {
                throw ActionExecutionError.processFailure(-1, "NSWorkspace could not open the URL.")
            }
            return url.absoluteString
        case .appleShortcut:
            guard !configuration.appleShortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ActionExecutionError.processFailure(-1, "Enter an Apple Shortcut name.")
            }
            return try await run(
                executable: "/usr/bin/shortcuts",
                arguments: ["run", configuration.appleShortcutName],
                timeout: configuration.commandTimeout
            )
        case .shellCommand:
            guard configuration.shellCommandEnabled else { throw ActionExecutionError.commandDisabled }
            guard configuration.executablePath.hasPrefix("/") else { throw ActionExecutionError.invalidExecutable }
            return try await run(
                executable: configuration.executablePath,
                arguments: configuration.arguments,
                timeout: configuration.commandTimeout
            )
        case .mediaControl:
            throw ActionExecutionError.unsupportedMediaAction
        }
    }

    private func launchApplication(_ configuration: KeyConfiguration) async throws -> String {
        guard let bookmark = configuration.applicationBookmark else {
            throw ActionExecutionError.inaccessibleApplication
        }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), !stale else {
            throw ActionExecutionError.inaccessibleApplication
        }

        return try await withCheckedThrowingContinuation { continuation in
            let options = NSWorkspace.OpenConfiguration()
            options.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: options) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: url.lastPathComponent)
                }
            }
        }
    }

    private func postShortcut(_ shortcut: ShortcutDefinition) throws -> String {
        guard shortcut.isValid else { throw ActionExecutionError.invalidShortcut }
        guard AXIsProcessTrusted() else { throw ActionExecutionError.accessibilityRequired }

        var flags: CGEventFlags = []
        if shortcut.command { flags.insert(.maskCommand) }
        if shortcut.option { flags.insert(.maskAlternate) }
        if shortcut.control { flags.insert(.maskControl) }
        if shortcut.shift { flags.insert(.maskShift) }

        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(shortcut.keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(shortcut.keyCode), keyDown: false) else {
            throw ActionExecutionError.invalidShortcut
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return shortcut.displayText
    }

    private func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> String {
        commandIsRunning = true
        defer { commandIsRunning = false }
        let result = try await Self.runProcess(executable: executable, arguments: arguments, timeout: timeout)
        if result.timedOut { throw ActionExecutionError.timedOut }
        guard result.status == 0 else {
            throw ActionExecutionError.processFailure(result.status, result.standardError)
        }
        return result.standardOutput.isEmpty ? "Process exited successfully." : result.standardOutput
    }

    nonisolated static func runProcess(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        let deadline = ContinuousClock.now + .seconds(max(0.1, timeout))
        var timedOut = false

        while process.isRunning {
            if ContinuousClock.now >= deadline {
                timedOut = true
                process.terminate()
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        process.waitUntilExit()

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: output, as: UTF8.self),
            standardError: String(decoding: error, as: UTF8.self),
            timedOut: timedOut
        )
    }
}
