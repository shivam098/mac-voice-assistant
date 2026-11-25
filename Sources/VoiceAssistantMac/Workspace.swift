import AppKit
import CoreGraphics

/// A running app, as the desktop needs it (NSRunningApplication).
public struct RunningApp: Equatable, Sendable {
    public var processIdentifier: pid_t
    public var bundleIdentifier: String?

    /// Its name as you see it (localizedName), which macOS translates for some apps.
    public var name: String?
    public var bundleURL: URL?

    /// The executable's file name, for an app without a bundle identifier.
    public var executableName: String?

    /// It has a Dock icon and menus (activationPolicy .regular), unlike agents and background helpers.
    public var isRegular: Bool

    public init(
        processIdentifier: pid_t, bundleIdentifier: String? = nil, name: String? = nil, bundleURL: URL? = nil,
        executableName: String? = nil, isRegular: Bool = true
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.bundleURL = bundleURL
        self.executableName = executableName
        self.isRegular = isRegular
    }

    /// What `WindowInfo.processName` holds on the Mac: the bundle identifier, else the executable's name.
    public var processName: String { bundleIdentifier ?? executableName ?? name ?? "" }
}

/// An item of a folder, for finding the installed apps.
public struct FolderItem: Equatable, Sendable {
    public var url: URL

    /// A folder to look in, not a package such as an app bundle.
    public var isFolder: Bool

    public init(url: URL, isFolder: Bool) {
        self.url = url
        self.isFolder = isFolder
    }
}

/// An installed app bundle.
public struct AppBundle: Equatable, Sendable {
    public var url: URL
    public var bundleIdentifier: String?

    /// The name Finder shows (FileManager.displayName, without ".app"), which macOS translates for some apps.
    public var displayName: String

    public init(url: URL, bundleIdentifier: String?, displayName: String) {
        self.url = url
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }
}

/// A screen, in Accessibility's coordinates.
public struct ScreenArea: Equatable, Sendable {
    public var frame: CGRect

    /// The part apps use: without the menu bar and the Dock (NSScreen.visibleFrame).
    public var visibleFrame: CGRect

    public init(frame: CGRect, visibleFrame: CGRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// What the desktop asks NSWorkspace, NSRunningApplication, the window server and the file system, behind a protocol
/// so it can be tested without other apps (`FakeWorkspace` in the tests).
public protocol WorkspaceSystem: AnyObject {
    func app(_ processIdentifier: pid_t) -> RunningApp?

    /// The running apps.
    func runningApps() -> [RunningApp]

    /// NSWorkspace.frontmostApplication: the app whose menus show, which isn't always the app taking the keys.
    func frontmostApp() -> RunningApp?

    /// Where the app with this bundle identifier is installed (NSWorkspace.urlForApplication(withBundleIdentifier:)).
    func applicationURL(bundleIdentifier: String) -> URL?

    /// Starts the app at `url`, or brings it to the front if it runs (NSWorkspace.openApplication), and comes back once
    /// macOS has started it; throws what macOS reports.
    func launch(_ url: URL) async throws -> RunningApp?

    /// Asks NSRunningApplication to bring the app to the front.
    @discardableResult
    func activate(_ processIdentifier: pid_t) -> Bool

    /// Opens `url` with the app at `appURL`, or with its default app (NSWorkspace.open); throws what macOS reports.
    func open(_ url: URL, withApplicationAt appURL: URL?) async throws

    /// The numbers of the windows on screen, front-most first (CGWindowListCopyWindowInfo).
    func windowNumbersFrontToBack() -> [Int]

    /// The screens, each one's frame and the part apps use (without the menu bar and the Dock), in Accessibility's
    /// coordinates: points from the top left of the main display, y down.
    func screens() async -> [ScreenArea]

    /// The items of a folder; empty when it can't be read.
    func folderItems(_ folder: URL) -> [FolderItem]

    /// The app bundle at `url`; nil when it isn't one.
    func appBundle(at url: URL) -> AppBundle?
}

/// NSWorkspace, NSRunningApplication, CGWindowList and FileManager themselves.
public final class SystemWorkspace: WorkspaceSystem, @unchecked Sendable {
    public init() {}

    public func app(_ processIdentifier: pid_t) -> RunningApp? {
        NSRunningApplication(processIdentifier: processIdentifier).flatMap(Self.running)
    }

    public func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.compactMap(Self.running)
    }

    public func frontmostApp() -> RunningApp? {
        NSWorkspace.shared.frontmostApplication.flatMap(Self.running)
    }

    public func applicationURL(bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    public func launch(_ url: URL) async throws -> RunningApp? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: app.flatMap(Self.running))
                }
            }
        }
    }

    @discardableResult
    public func activate(_ processIdentifier: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: processIdentifier) else { return false }
        if #available(macOS 14, *) {
            // Since macOS 14 an app can't take the front from the one there: Accessibility's AXFrontmost does it.
            return app.activate(options: [])
        } else {
            return app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    public func open(_ url: URL, withApplicationAt appURL: URL?) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let done: @Sendable (NSRunningApplication?, Error?) -> Void = { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }

            if let appURL {
                NSWorkspace.shared.open(
                    [url], withApplicationAt: appURL, configuration: configuration, completionHandler: done)
            } else {
                NSWorkspace.shared.open(url, configuration: configuration, completionHandler: done)
            }
        }
    }

    public func windowNumbersFrontToBack() -> [Int] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { $0[kCGWindowNumber as String] as? Int }
    }

    /// NSScreen's frames, which start at the bottom left of the main display (the first screen, with the menu bar),
    /// turned over.
    public func screens() async -> [ScreenArea] {
        await MainActor.run {
            let screens = NSScreen.screens
            guard let main = screens.first else { return [] }
            let top = main.frame.maxY
            func flipped(_ rect: CGRect) -> CGRect {
                CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
            }

            return screens.map { ScreenArea(frame: flipped($0.frame), visibleFrame: flipped($0.visibleFrame)) }
        }
    }

    public func folderItems(_ folder: URL) -> [FolderItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return FolderItem(url: url, isFolder: values?.isDirectory == true && values?.isPackage != true)
        }
    }

    public func appBundle(at url: URL) -> AppBundle? {
        guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { return nil }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.lowercased().hasSuffix(".app") {
            name = String(name.dropLast(4))
        }

        return AppBundle(url: url, bundleIdentifier: Bundle(url: url)?.bundleIdentifier, displayName: name)
    }

    private static func running(_ app: NSRunningApplication) -> RunningApp? {
        guard !app.isTerminated else { return nil }
        return RunningApp(
            processIdentifier: app.processIdentifier, bundleIdentifier: app.bundleIdentifier, name: app.localizedName,
            bundleURL: app.bundleURL, executableName: app.executableURL?.lastPathComponent,
            isRegular: app.activationPolicy == .regular)
    }
}
