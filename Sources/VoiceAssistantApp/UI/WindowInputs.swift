import AppKit
import VoiceAssistantCore
import VoiceAssistantMac

/// What the window asks of the assistant and reads from it: members of the same names as the assistant host's
/// (Windows' pages call them on `AssistantHost`), so the host can be passed as it is. Safe from any thread.
public protocol AssistantControls {
    /// What it's doing now; `MainWindow.showStatus` tells the window when it changes.
    var mode: InteractionMode { get }
    /// Dictation is in Hindi + English, with the fast model or, when `hinglishAccurate`, the larger one.
    var hinglishDictation: Bool { get }
    var hinglishAccurate: Bool { get }
    /// Pauses listening, or starts it.
    func toggleListening()
    func setDictationLanguage(hinglish: Bool, accurate: Bool)
    /// Forgets the rephrasings and favourite apps it learned.
    func forgetLearned()
}

/// The AI brain as Settings shows and drives it: members of the same names as the assistant's brain (`LlamaBrain`,
/// with its files' `folder` and `missingBytes`). `MainWindow.brainChanged()` tells the window when its status changes.
public protocol BrainControls {
    var status: BrainStatus { get }
    /// The download can start: this Mac can run the brain, something is missing, and no download is running.
    var canDownload: Bool { get }
    /// Where its files go.
    var folder: String { get }
    /// Bytes a download would fetch now.
    var missingBytes: Int64 { get }
    /// Downloads what's missing, carrying on where a download stopped, then loads the model.
    @discardableResult
    func startDownload() -> Task<Void, Never>
    /// Stops the download; the next one carries on where it stopped.
    func cancelDownload()
}

/// "Start when I log in" (Windows' `StartupRegistration`): Voice Assistant as a login item, switched on or off at once.
public struct StartAtLogin {
    /// It's on now.
    public var isEnabled: @MainActor () -> Bool
    /// Switches it; Settings reads `isEnabled` again after.
    public var set: @MainActor (Bool) -> Void

    public init(isEnabled: @escaping @MainActor () -> Bool, set: @escaping @MainActor (Bool) -> Void) {
        self.isEnabled = isEnabled
        self.set = set
    }
}

/// The keys the window's texts name, as macOS writes them.
public struct KeyNames: Equatable, Sendable {
    /// The dictation key: "Fn" or "Right Option".
    public var dictation: String
    /// The hotkeys: pause and resume, paste last, and the dictation language; empty for one that isn't set.
    public var hotkeys: MenuHotkeys

    public init(dictation: String = "Fn", hotkeys: MenuHotkeys = MenuHotkeys()) {
        self.dictation = dictation
        self.hotkeys = hotkeys
    }
}

/// Opens folders, files and System Settings' panes: Finder, TextEdit and System Settings in the app, a recorder in
/// tests.
@MainActor
public protocol FileOpener {
    /// Shows a folder in Finder, or opens a file or a URL with its app.
    func open(_ url: URL)
    /// Opens a text file in TextEdit (Windows opens settings.json in Notepad).
    func openText(_ url: URL)
}

/// The Mac's: NSWorkspace.
public struct WorkspaceOpener: FileOpener {
    public init() {}

    public func open(_ url: URL) {
        _ = NSWorkspace.shared.open(url)
    }

    public func openText(_ url: URL) {
        guard let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
            _ = NSWorkspace.shared.open(url)
            return
        }

        NSWorkspace.shared.open(
            [url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}
