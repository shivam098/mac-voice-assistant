import AppKit

/// Voice Assistant in the menu bar while the app is being built: it starts the log and the settings as the Windows app
/// does when it starts, and shows a status item whose menu says the app is in development and quits it. The assistant
/// host (listening for "Hey Jarvis", Fn dictation) and the real menu bar, pill and window replace it.
/// `Sources/VoiceAssistant/main.swift` only calls `main`.
@MainActor
public final class AppLauncher: NSObject, NSApplicationDelegate {
    /// What the menu says.
    nonisolated static let inDevelopment = "Voice Assistant for Mac — in development"

    /// Runs the app until it quits. `--bundle-identifier` prints the app's bundle identifier instead, for
    /// scripts/make-app.sh's Info.plist.
    public static func main(_ arguments: [String]) {
        if arguments.dropFirst().contains("--bundle-identifier") {
            print(VoiceAssistantApp.bundleIdentifier)
            return
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let launcher = AppLauncher(paths: .standard)
        app.delegate = launcher
        withExtendedLifetime(launcher) {
            app.run()
        }
    }

    /// The version from the app's Info.plist, else the package's.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? VoiceAssistantApp.version
    }

    private let paths: AppPaths
    private var statusItem: NSStatusItem?

    init(paths: AppPaths) {
        self.paths = paths
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Log.start(in: paths.logs)
        #if arch(arm64)
        Log.info("starting \(Self.version) on Arm64")
        #else
        Log.info("starting \(Self.version) on X64")
        #endif
        _ = AppSettings.loadOrCreate(from: paths.settingsFile)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice Assistant") {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "VA"
        }

        item.menu = Self.menu()
        statusItem = item
    }

    public func applicationWillTerminate(_ notification: Notification) {
        Log.info("exiting")
    }

    /// The status item's menu: what the app is, and Quit.
    static func menu() -> NSMenu {
        let menu = NSMenu()
        let status = NSMenuItem(title: inDevelopment, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit Voice Assistant", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }
}
