import AppKit
import Foundation

struct ActionPresentation: Equatable {
    let title: String
    let detail: String
    let symbolName: String
    let tooltip: String

    init(configuration: KeyConfiguration) {
        let kind = configuration.actionKind
        switch kind {
        case .none:
            title = "Unassigned"
            detail = "No action"
            symbolName = kind.symbol
            tooltip = "No action is assigned"
        case .launchApplication:
            let configured = configuration.isActionConfigured
            title = configured ? configuration.applicationName : "Not configured"
            detail = kind.title
            symbolName = kind.symbol
            tooltip = configured ? configuration.applicationName : "No application selected"
        case .keyboardShortcut:
            let configured = configuration.isActionConfigured
            let shortcut = configuration.shortcut.displayText
            title = configured ? shortcut : "Not configured"
            detail = kind.title
            symbolName = kind.symbol
            tooltip = configured ? "Keyboard shortcut \(shortcut)" : "No keyboard shortcut recorded"
        case .openURL:
            let configured = configuration.isActionConfigured
            title = configured ? Self.readableHost(configuration.urlString) : "Not configured"
            detail = kind.title
            symbolName = kind.symbol
            tooltip = configured ? configuration.urlString : "No valid URL configured"
        case .appleShortcut:
            let configured = configuration.isActionConfigured
            title = configured ? configuration.appleShortcutName : "Not configured"
            detail = kind.title
            symbolName = kind.symbol
            tooltip = configured ? configuration.appleShortcutName : "No Apple Shortcut configured"
        case .shellCommand:
            let configured = configuration.isActionConfigured
            let executable = URL(fileURLWithPath: configuration.executablePath).lastPathComponent
            title = configured ? executable : "Not configured"
            detail = kind.title
            symbolName = kind.symbol
            tooltip = configured ? "Runs \(executable)" : "No enabled command configured"
        case .mediaControl:
            title = configuration.mediaAction.title
            detail = kind.title
            symbolName = configuration.mediaAction.symbolName
            tooltip = configuration.mediaAction.title
        }
    }

    static func readableHost(_ value: String) -> String {
        guard let url = URLValidator.validatedHTTPURL(value),
              let host = url.host(percentEncoded: false) else {
            return "Not configured"
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

extension KeyConfiguration {
    var isActionConfigured: Bool {
        switch actionKind {
        case .none:
            false
        case .launchApplication:
            applicationBookmark != nil && !applicationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .keyboardShortcut:
            shortcut.isValid
        case .openURL:
            URLValidator.validatedHTTPURL(urlString) != nil
        case .appleShortcut:
            !appleShortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .shellCommand:
            shellCommandEnabled
                && executablePath.hasPrefix("/")
                && !URL(fileURLWithPath: executablePath).lastPathComponent.isEmpty
        case .mediaControl:
            true
        }
    }
}

extension MediaAction {
    var symbolName: String {
        switch self {
        case .playPause: "playpause.fill"
        case .next: "forward.end.fill"
        case .previous: "backward.end.fill"
        case .volumeUp: "speaker.wave.3.fill"
        case .volumeDown: "speaker.wave.1.fill"
        case .mute: "speaker.slash.fill"
        }
    }
}

@MainActor
final class ApplicationIconCache {
    static let shared = ApplicationIconCache()

    private let images = NSCache<NSString, NSImage>()
    private var resolvedURLs: [String: URL] = [:]
    private var missingKeys: Set<String> = []

    private init() {
        images.countLimit = 24
    }

    func icon(for configuration: KeyConfiguration) -> NSImage? {
        guard configuration.actionKind == .launchApplication else { return nil }
        let key = cacheKey(for: configuration)

        if let cached = images.object(forKey: key as NSString) {
            return cached
        }
        guard let url = applicationURL(for: configuration) else { return nil }

        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 64, height: 64)
        images.setObject(image, forKey: key as NSString)
        return image
    }

    func applicationURL(for configuration: KeyConfiguration) -> URL? {
        let key = cacheKey(for: configuration)
        if let cached = resolvedURLs[key] { return cached }
        if missingKeys.contains(key) { return nil }
        guard let bookmark = configuration.applicationBookmark else {
            missingKeys.insert(key)
            return nil
        }

        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), FileManager.default.fileExists(atPath: url.path) else {
            missingKeys.insert(key)
            return nil
        }

        resolvedURLs[key] = url
        return url
    }

    func isMissing(_ configuration: KeyConfiguration) -> Bool {
        configuration.actionKind == .launchApplication
            && !configuration.applicationName.isEmpty
            && applicationURL(for: configuration) == nil
    }

    func invalidate(_ configuration: KeyConfiguration) {
        let key = cacheKey(for: configuration)
        images.removeObject(forKey: key as NSString)
        resolvedURLs.removeValue(forKey: key)
        missingKeys.remove(key)
    }

    private func cacheKey(for configuration: KeyConfiguration) -> String {
        if let bookmark = configuration.applicationBookmark {
            return bookmark.base64EncodedString()
        }
        return "name:\(configuration.applicationName)"
    }
}

@MainActor
final class ProfileApplicationIconCache {
    static let shared = ProfileApplicationIconCache()

    private let images = NSCache<NSString, NSImage>()
    private var resolvedURLs: [String: URL] = [:]

    private init() {
        images.countLimit = 24
    }

    func icon(for profile: ApplicationProfile) -> NSImage? {
        if let cached = images.object(forKey: profile.bundleIdentifier as NSString) {
            return cached
        }
        guard let url = applicationURL(for: profile) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 64, height: 64)
        images.setObject(image, forKey: profile.bundleIdentifier as NSString)
        return image
    }

    func applicationURL(for profile: ApplicationProfile) -> URL? {
        if let cached = resolvedURLs[profile.bundleIdentifier],
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        if let bookmark = profile.applicationBookmark {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), FileManager.default.fileExists(atPath: url.path) {
                resolvedURLs[profile.bundleIdentifier] = url
                return url
            }
        }
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: profile.bundleIdentifier
        ) else { return nil }
        resolvedURLs[profile.bundleIdentifier] = url
        return url
    }

    func invalidate(bundleIdentifier: String) {
        images.removeObject(forKey: bundleIdentifier as NSString)
        resolvedURLs.removeValue(forKey: bundleIdentifier)
    }
}
