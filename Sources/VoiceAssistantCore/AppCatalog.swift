import ThumbFreeCore

/// An application the assistant can open and type into. The configured apps come from settings and the installed
/// ones from the desktop layer, so the lists live in the app, not here.
public struct AppEntry: Hashable, Sendable {
    public var name: String
    public var aliases: [String]

    /// How the desktop layer starts the app (on the Mac, its bundle identifier or path).
    public var launch: String

    /// Process names used to find an already-running window.
    public var processNames: [String]

    /// Text the main window's title must contain, if any.
    public var windowTitleContains: String?

    public var submitKeys: String

    public var newLineKeys: String

    /// How "start typing" finds the text area when the focus is elsewhere: "Bottom" (a chat's message box at the bottom
    /// of the window) or "Largest" (a document editor). Nil: type wherever the focus already is.
    public var textArea: String?

    /// The accessible name (or part of its help text) of the right text area when the window has several, such as
    /// GitHub Copilot's "Message" box beside its side-panel editor. The focus is moved there.
    public var textAreaName: String?

    /// Keys that focus the app's search box (in browsers, the address and search bar).
    public var searchKeys: String?

    /// Keys that focus the address bar (browsers).
    public var addressBarKeys: String?

    /// When "open" finds the app already running, these keys give a fresh window.
    public var newWindowKeys: String?

    /// After launching the app, these keys give a blank document (for apps that reopen their last documents).
    public var newDocumentKeys: String?

    public init(
        name: String,
        aliases: [String] = [],
        launch: String,
        processNames: [String] = [],
        windowTitleContains: String? = nil,
        submitKeys: String = "Enter",
        newLineKeys: String = "Shift+Enter",
        textArea: String? = nil,
        textAreaName: String? = nil,
        searchKeys: String? = nil,
        addressBarKeys: String? = nil,
        newWindowKeys: String? = nil,
        newDocumentKeys: String? = nil
    ) {
        self.name = name
        self.aliases = aliases
        self.launch = launch
        self.processNames = processNames
        self.windowTitleContains = windowTitleContains
        self.submitKeys = submitKeys
        self.newLineKeys = newLineKeys
        self.textArea = textArea
        self.textAreaName = textAreaName
        self.searchKeys = searchKeys
        self.addressBarKeys = addressBarKeys
        self.newWindowKeys = newWindowKeys
        self.newDocumentKeys = newDocumentKeys
    }
}

public enum AppResolution: Equatable, Sendable {
    case found(AppEntry)

    /// Several apps fit; their names, for "Which one? …".
    case ambiguous([String])

    case notFound
}

/// Resolves spoken app names: the configured apps, then the installed ones; exactly, then relaxed ("teams" is
/// "Microsoft Teams", "outlook" is "Outlook (new)"), then near misses ("notpad", "crome"). Ties go to the app the user
/// opens most.
public final class AppCatalog {
    private let configured: [AppEntry]
    private let memory: PhraseMemory?
    private var discovered: [AppEntry] = []

    public init(_ configured: [AppEntry], memory: PhraseMemory? = nil) {
        self.configured = configured
        self.memory = memory
    }

    public func setDiscoveredApps(_ discovered: [AppEntry]) {
        self.discovered = discovered
    }

    /// True if the spoken name is exactly an app's name or alias (no fuzzy matching).
    public func hasExactName(_ spokenName: String) -> Bool {
        let key = TranscriptText.compact(spokenName)
        return !key.isEmpty && (configured + discovered).contains { NetText.contains(Self.keys($0), key) }
    }

    /// - Parameter fuzzy: False: only an app's name or alias, also without its vendor ("outlook"), never a prefix or a
    ///   slip ("youtube" is not YouTube Music, "gmail" not Mail).
    public func resolve(_ spokenName: String, fuzzy: Bool = true) -> AppResolution {
        let key = TranscriptText.compact(spokenName)
        if key.isEmpty {
            return .notFound
        }

        if let app = configured.first(where: { NetText.contains(Self.keys($0), key) }) {
            return .found(app)
        }

        // Each app once, by how it's launched; a configured app comes first and so keeps its place.
        var launches = Set<[Unicode.Scalar]>()
        var all: [Candidate] = []
        for (app, isConfigured) in configured.map({ ($0, true) }) + discovered.map({ ($0, false) }) {
            if launches.insert(DotNet.ordinal(app.launch)).inserted {
                all.append(Candidate(app: app, configured: isConfigured))
            }
        }

        let keyLength = key.utf16.count
        let tiers: [(AppEntry) -> Bool] = [
            { NetText.contains(Self.keys($0), key) },
            { NetText.contains(Self.relaxedKeys($0), key) },
            { app in
                fuzzy && keyLength >= 4 && Self.relaxedKeys(app).contains {
                    DotNet.startsWith($0, key) && $0.utf16.count - keyLength <= 8
                }
            },
        ]

        for tier in tiers {
            let matches = all.filter { tier($0.app) }
            if !matches.isEmpty {
                return pick(matches)
            }
        }

        // Near misses from speech recognition or pronunciation: 1–2 letters different in longer names.
        let allowed = !fuzzy ? 0 : keyLength < 4 ? 0 : keyLength <= 7 ? 1 : 2
        if allowed > 0 {
            // C#'s Min throws for an app without a single key (a name of punctuation only); here it's skipped.
            let scored = all.compactMap { candidate -> (candidate: Candidate, distance: Int)? in
                guard let distance = Self.relaxedKeys(candidate.app).map({ NameMatcher.levenshtein($0, key) }).min()
                else { return nil }
                return distance <= allowed ? (candidate, distance) : nil
            }

            if let best = scored.map({ $0.distance }).min() {
                return pick(scored.filter { $0.distance == best }.map { $0.candidate })
            }
        }

        return .notFound
    }

    /// The configured profile (submit keys, where to type) of a running process.
    public func findProfileForProcess(_ processName: String, _ windowTitle: String?) -> AppEntry? {
        configured.first { app in
            app.processNames.contains { DotNet.equalsOrdinalIgnoreCase($0, processName) }
                && (app.windowTitleContains.map { part in
                    windowTitle.map { NetText.containsOrdinalIgnoreCase($0, part) } ?? false
                } ?? true)
        }
    }

    private struct Candidate {
        let app: AppEntry
        let configured: Bool
    }

    private func pick(_ matches: [Candidate]) -> AppResolution {
        if matches.count == 1 {
            return .found(matches[0].app)
        }

        // Configured apps (with tuned behaviour) win; then the one the user opens most, if it clearly leads.
        let configuredMatches = matches.filter { $0.configured }
        if configuredMatches.count == 1 {
            return .found(configuredMatches[0].app)
        }

        if let memory {
            let ranked = DotNet.orderByDescending(matches) { memory.usesOf($0.app.name) }
            if memory.usesOf(ranked[0].app.name) > memory.usesOf(ranked[1].app.name) {
                return .found(ranked[0].app)
            }
        }

        return .ambiguous(matches.map { $0.app.name })
    }

    private static func keys(_ app: AppEntry) -> [String] {
        NetText.distinct([TranscriptText.compact(app.name)] + app.aliases.map { TranscriptText.compact($0) })
    }

    /// The name without its vendor and parenthetical as well: "Microsoft Outlook (new)" is "outlook".
    private static func relaxedKeys(_ app: AppEntry) -> [String] {
        let name = parentheticalRegex.replace(app.name, " ")
        let relaxed = keys(app) + [TranscriptText.compact(name), TranscriptText.compact(stripVendor(DotNet.trim(name)))]
        return NetText.distinct(relaxed).filter { !$0.isEmpty }
    }

    private static func stripVendor(_ name: String) -> String {
        for vendor in ["Microsoft ", "Google ", "Mozilla ", "Adobe "]
        where NetText.startsWithOrdinalIgnoreCase(name, vendor) {
            return DotNet.string(name.unicodeScalars.dropFirst(vendor.unicodeScalars.count))
        }

        return name
    }

    private static let parentheticalRegex = NetRegex(#"\([^)]*\)"#)
}
