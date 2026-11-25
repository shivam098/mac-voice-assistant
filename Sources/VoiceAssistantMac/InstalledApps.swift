import Foundation
import VoiceAssistantCore

/// The apps installed on this Mac, for "open …" (windows-voice-assistant `StartMenuApps`, which lists the Start menu's
/// apps): the app bundles in /Applications, /System/Applications and ~/Applications and the folders in them (Utilities,
/// a vendor's folder), then running apps found nowhere else (Finder, an app started from Downloads). Each is named as
/// Finder shows it, with its bundle's file name as another name when that differs (German shows Calculator as
/// "Rechner"), started by its bundle identifier and recognised by it when it runs, as the core's `AppCatalog` expects
/// on the Mac (Windows' entries have a name and a launch command only).
public enum InstalledApps {
    /// How deep folders are looked into, below each of the three.
    static let depth = 3

    /// The folders looked in, in this order: an app in more than one counts once, as found first.
    public static func folders(home: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    /// The installed and running apps, sorted by name.
    public static func discover(
        _ workspace: WorkspaceSystem, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [AppEntry] {
        var found: [AppEntry] = []
        var seen = Set<String>()
        func add(_ name: String, fileName: String?, bundleIdentifier: String?, path: String) {
            let name = name.trimmingCharacters(in: .whitespaces)
            let key = (bundleIdentifier ?? path).lowercased()
            guard !name.isEmpty, seen.insert(key).inserted else { return }
            var aliases: [String] = []
            if let fileName = fileName?.trimmingCharacters(in: .whitespaces), !fileName.isEmpty,
               fileName.caseInsensitiveCompare(name) != .orderedSame {
                aliases.append(fileName)
            }

            found.append(
                AppEntry(
                    name: name, aliases: aliases, launch: bundleIdentifier ?? path,
                    processNames: bundleIdentifier.map { [$0] } ?? []))
        }

        for folder in folders(home: home) {
            for bundle in bundles(in: folder, workspace, depth: depth) {
                add(
                    bundle.displayName, fileName: bundle.url.deletingPathExtension().lastPathComponent,
                    bundleIdentifier: bundle.bundleIdentifier, path: bundle.url.path)
            }
        }

        for app in workspace.runningApps() where app.isRegular {
            guard let name = app.name, let url = app.bundleURL else { continue }
            add(
                name, fileName: url.deletingPathExtension().lastPathComponent, bundleIdentifier: app.bundleIdentifier,
                path: url.path)
        }

        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The app bundles in `folder` and the folders in it, `depth` levels down; never inside an app.
    static func bundles(in folder: URL, _ workspace: WorkspaceSystem, depth: Int) -> [AppBundle] {
        var bundles: [AppBundle] = []
        for item in workspace.folderItems(folder) {
            if let bundle = workspace.appBundle(at: item.url) {
                bundles.append(bundle)
            } else if item.isFolder, depth > 1 {
                bundles += Self.bundles(in: item.url, workspace, depth: depth - 1)
            }
        }

        return bundles
    }
}
