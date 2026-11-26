import AppKit
import ThumbFreeCore
import ThumbFreeMac
import VoiceAssistantBoard
import VoiceAssistantCore

/// How Voice Assistant was started: its command line (windows-voice-assistant App.xaml.cs's `e.Args`).
struct LaunchOptions: Equatable {
    /// The self-test's script, and where its results go (by default next to it, as "<script>.out.txt").
    struct SelfTestFiles: Equatable {
        var script: String
        var output: String
    }

    /// `--bundle-identifier`: prints the app's bundle identifier, for scripts/make-app.sh's Info.plist.
    var printBundleIdentifier = false

    /// `--self-test <script> [<output>]`.
    var selfTest: SelfTestFiles?

    /// `--background`: started at login or by a restart while the window was closed, so the window stays closed.
    var background = false

    /// `--restarted`: the copy that "Save and restart" started, which waits longer for the old one to quit.
    var restarted = false

    init(_ arguments: [String]) {
        let given = Array(arguments.dropFirst())
        printBundleIdentifier = given.contains("--bundle-identifier")
        if given.count >= 2 && given[0] == "--self-test" {
            selfTest = SelfTestFiles(script: given[1], output: given.count > 2 ? given[2] : given[1] + ".out.txt")
        }

        background = given.contains(LoginItem.backgroundArgument)
        restarted = given.contains(AppController.restartedArgument)
    }
}

/// Voice Assistant, the app (windows-voice-assistant App.xaml.cs, without its windows): one copy at a time, the log,
/// the settings, the idea board, the assistant host, the pause, paste-last and language hotkeys, the dictation key
/// (Fn or Right Option, and Esc), the warning while ThumbFree runs, restarting and quitting; and the self-test. The
/// menu bar, the pill, the window and the reminders are the app's UI, which comes next: until then the menu says the
/// app is in development. `Sources/VoiceAssistant/main.swift` only calls `main`.
@MainActor
public final class AppController: NSObject, NSApplicationDelegate {
    /// What the menu says until the UI lands.
    nonisolated static let inDevelopment = "Voice Assistant for Mac — in development"

    nonisolated static let restartedArgument = "--restarted"

    /// What the warning says while ThumbFree runs with the same key.
    nonisolated static let thumbFreeNote =
        "ThumbFree is running too, with the same Fn key: quit one of them, or text is typed twice."

    /// What the warning says while macOS doesn't let the desktop act.
    nonisolated static let desktopNotAllowedNote =
        "Voice Assistant can't open apps or type for you yet: allow it in System Settings › Privacy & Security › "
        + "Accessibility."

    /// The topics of the notices that stay in force while what they say holds (`NoticeEvent`).
    enum NoticeTopic {
        static let thumbFree = "thumbFree"
        static let dictationKey = "dictationKey"
        static let desktop = "desktop"

        static func hotkey(_ purpose: String) -> String { "hotkey " + purpose }
    }

    /// Runs the app until it quits.
    public static func main(_ arguments: [String], parts: AppParts = .standard) {
        let options = LaunchOptions(arguments)
        if options.printBundleIdentifier {
            print(VoiceAssistantApp.bundleIdentifier)
            return
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = AppController(paths: .standard, parts: parts, options: options)
        app.delegate = controller
        withExtendedLifetime(controller) {
            app.run()
        }
    }

    /// The version from the app's Info.plist, else the package's.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? VoiceAssistantApp.version
    }

    // MARK: For the UI

    /// Voice Assistant was opened again while it runs (from Finder or Spotlight, or by a second copy): show the
    /// window (Windows' ShowWindow event).
    public let showRequested = HostEvent<Void>()

    /// Something to tell in a notification (Windows' tray balloons): a hotkey another app has or settings.json's chord
    /// that can't be read, the dictation key that can't be seen yet, the desktop's missing permission, ThumbFree
    /// running too, a restart that failed. The notices still in force reach a handler added later too, so the UI shows
    /// them whenever it subscribes; each is withdrawn once it no longer holds (the hotkey registered after a keyboard
    /// layout change, the permission given, ThumbFree quit). A failed restart is told once. Withdrawing isn't announced
    /// to the handlers already listening, so a lasting banner should follow `thumbFreeChanged` or
    /// `missingDesktopPermissions`, not `notice` alone.
    public let notice = NoticeEvent()

    /// ThumbFree started or quit while both use the same key: `thumbFreeRunsToo` changed, so the UI shows or clears its
    /// warning.
    public let thumbFreeChanged = HostEvent<Bool>()

    /// The assistant; nil until it starts, and in a build without a desktop.
    public private(set) var host: AssistantHost?

    /// The idea board in board.json.
    public private(set) var board: BoardStore?

    /// The settings as they were read at launch; changes apply after a restart, as on Windows.
    public private(set) var settings: AppSettings?

    /// Started at login or by a restart while the window was closed: the window stays closed.
    public private(set) var launchedInBackground = false

    /// ThumbFree runs too with the same key, so text would be typed twice.
    public private(set) var thumbFreeRunsToo = false

    /// What the desktop may not do yet: the permissions macOS hasn't given (Accessibility, which also lets it send
    /// keys), read now, for the UI to offer them.
    public var missingDesktopPermissions: [Permissions.Kind] { desktop?.missingPermissions?() ?? [] }

    // MARK: Parts

    private let paths: AppPaths
    private let parts: AppParts
    private let options: LaunchOptions
    private let instance: SingleInstance
    private let insertMethod = Locked("Paste")
    private let reader = FocusedField.Reader()
    private var desktop: DesktopParts?
    private var statusItem: NSStatusItem?
    private var hotkeys: [GlobalHotkey] = []
    private var keys: HotkeyTap?
    private var tapAllowed: HotkeyTap.Mode?
    private var desktopAllowed = true
    private var permissionTimer: Timer?
    private var otherApp: OtherApp?
    private var subscriptions: [HostSubscription] = []
    private var recording = false
    private var recordingId = 0
    private var quitting = false

    init(paths: AppPaths, parts: AppParts, options: LaunchOptions) {
        self.paths = paths
        self.parts = parts
        self.options = options
        instance = SingleInstance(path: (paths.data as NSString).appendingPathComponent("instance.lock"))
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if let files = options.selfTest {
            runSelfTest(files)
            return
        }

        launchedInBackground = options.background || LoginItem.launchedAtLogin()
        let owner: Bool
        do {
            // After "Save and restart" the old copy may need a moment to quit.
            owner = try instance.acquire(waiting: options.restarted ? 15 : 3)
        } catch {
            // No lock file: carry on as the only copy, as Windows does with an abandoned mutex.
            owner = true
        }

        guard owner else {
            // Opening it again (Finder, Spotlight) shows the running copy.
            if !launchedInBackground {
                SingleInstance.showRunningCopy()
            }

            NSApp.terminate(nil)
            return
        }

        Log.start(in: paths.logs)
        #if arch(arm64)
        Log.info("starting \(Self.version) on Arm64")
        #else
        Log.info("starting \(Self.version) on X64")
        #endif
        let settings = AppSettings.loadOrCreate(from: paths.settingsFile)
        self.settings = settings
        insertMethod.value = settings.insertMethod
        let board: BoardStore
        do {
            board = try BoardStore(path: paths.boardFile)
        } catch {
            Self.failedToStart(error, logs: paths.logs)
            return
        }

        self.board = board
        statusItem = Self.makeStatusItem()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showRequestedByAnotherCopy(_:)), name: SingleInstance.showNotification,
            object: nil, suspensionBehavior: .deliverImmediately)
        guard let desktop = parts.desktopParts(insertMethod: insertMethod) else {
            Log.info("no desktop in this build: the assistant doesn't start")
            return
        }

        self.desktop = desktop

        // Chromium and Electron apps describe their pages to Accessibility only once an assistive app asks.
        reader.startWaking()
        let host = AssistantHost(
            settings: settings, paths: paths, parts: parts.hostParts(settings, paths, desktop: desktop), board: board)
        self.host = host
        subscriptions.append(host.captureStopped.subscribe { [weak self] id in
            MainActor.assumeIsolated { self?.captureStopped(id) }
        })
        registerHotkeys(settings, host)
        if settings.pushToTalk {
            installDictationKeys(settings)
        }

        warnIfThumbFreeRuns()
        checkDesktopPermissions()
        watchPermissions()
        host.start()
    }

    /// Opening Voice Assistant again while it runs (Finder, Spotlight).
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showRequested.send(())
        return false
    }

    /// Quitting stops listening, the models and the AI brain's server first (C#'s `OnExit` and the host's `Dispose`).
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting {
            return .terminateLater
        }

        guard let host else { return .terminateNow }
        quitting = true
        Log.info("exiting")
        stopInput()
        Task { @MainActor in
            await host.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    public func applicationWillTerminate(_ notification: Notification) {
        stopInput()
        instance.release()
    }

    /// "Save and restart" (C#'s `Restart`): starts a new copy, which waits for this one to quit, then quits.
    /// `windowVisible`: the new copy opens its window too.
    public func restart(windowVisible: Bool = false) {
        var arguments = [Self.restartedArgument]
        if !windowVisible {
            arguments.append(LoginItem.backgroundArgument)
        }

        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            // A bare binary (swift run): started again directly.
            let process = Process()
            process.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = arguments
            do {
                try process.run()
                NSApp.terminate(nil)
            } catch {
                Log.warn("restart failed: \(Log.kind(of: error))")
                tell("Couldn't restart. Quit from the menu bar and start Voice Assistant again.")
            }

            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = arguments
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { [weak self] _, error in
            let controller = self
            let started = error == nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated { controller?.restarted(started) }
            }
        }
    }

    // MARK: Keys

    /// C#'s `TryRegister` for the three hotkeys, as the Mac registers them (`AppSettings.macHotkey`).
    private func registerHotkeys(_ settings: AppSettings, _ host: AssistantHost) {
        register(settings.macHotkey, "pause/resume") { host.toggleListening() }
        register(settings.macPasteLastHotkey, "paste last dictation") { host.pasteLastTranscript() }
        register(settings.macDictationLanguageHotkey, "switch dictation language") { host.toggleDictationLanguage() }
    }

    /// Registers one of the hotkeys, telling the UI when another app has it or settings.json's chord can't be read (a
    /// Windows hotkey such as F24, say); both notices stay in force for a UI that subscribes later.
    func register(_ chord: String, _ purpose: String, _ pressed: @escaping () -> Void) {
        let topic = NoticeTopic.hotkey(purpose)
        do {
            let hotkey = try GlobalHotkey(chord, pressed: pressed)
            hotkeys.append(hotkey)
            let taken = "\(AppSettings.hotkeyLabel(chord)) (\(purpose)) is used by another app."
            if !hotkey.isRegistered {
                tell(taken, topic: topic)
            }

            // A letter's hotkey moves with the keyboard layout, maybe to a key another app has.
            hotkey.registrationChanged = { [weak self] registered in
                if registered {
                    Log.info("hotkey for \(purpose) registered again after a keyboard layout change")
                    self?.notice.withdraw(topic)
                } else {
                    Log.warn("hotkey for \(purpose) lost after a keyboard layout change")
                    self?.tell(taken, topic: topic)
                }
            }
        } catch {
            tell(AssistantHost.message(error), topic: topic)
        }
    }

    /// Tap the dictation key to start dictating, tap it again to finish; Esc cancels, and stops the AI brain (C#'s
    /// `InstallDictationKeys`).
    private func installDictationKeys(_ settings: AppSettings) {
        let source = EscapeWatchingSource(HotkeyTap.SystemTap()) { [weak self] in
            let controller = self
            DispatchQueue.main.async {
                MainActor.assumeIsolated { controller?.escapePressed() }
            }
        }

        let keys = HotkeyTap(tapKey: settings.dictationKey, source: source)
        keys.onCommand = { [weak self] command in self?.keyCommand(command) }
        keys.onBlocked = { [weak self] blocker in
            switch blocker {
            case .secureInput:
                // As ThumbFree says it.
                self?.host?.report(.warning, "Secure Input is on, so dictation can't start.")
            }
        }

        self.keys = keys
        tapAllowed = allowedTap()
        let mode = keys.start()
        Log.info("dictation keys: \(mode)")
        noteDictationKeys(mode)
    }

    private func keyCommand(_ command: FnTapKeys.Command) {
        switch command {
        case .start:
            if !recording {
                recording = true
                recordingId += 1
                keys?.isRecording = true
                host?.beginDictationCapture(recordingId)
            }
        case .finish:
            if recording {
                endDictation(cancel: false)
            }
        case .cancel:
            if recording {
                endDictation(cancel: true)
            }
        }
    }

    private func endDictation(cancel: Bool) {
        recording = false
        keys?.isRecording = false
        host?.endDictationCapture(cancel: cancel)
    }

    /// The recording couldn't start or stopped by itself: the keys stop treating the next tap (and Esc) as recording.
    private func captureStopped(_ id: Int) {
        if id == recordingId && recording {
            recording = false
            keys?.isRecording = false
        }
    }

    /// Esc while not recording (it still reaches the app in front): stops the AI brain if it's acting. It comes
    /// before the keys' own handling of that Esc, so `recording` still says whether it cancels a recording.
    private func escapePressed() {
        if !recording {
            host?.cancelBrainAction()
        }
    }

    /// Every 3 s: the tap is made again once a permission is given (or taken back) in System Settings, and the
    /// desktop's warning is withdrawn once it's allowed.
    private func watchPermissions() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.permissionsMayHaveChanged() }
        }
    }

    private func permissionsMayHaveChanged() {
        checkDesktopPermissions()
        guard let keys, !recording else { return }
        let allowed = allowedTap()
        if allowed != tapAllowed {
            tapAllowed = allowed
            let mode = keys.start()
            Log.info("dictation keys: \(mode)")
            noteDictationKeys(mode)
        }
    }

    /// Whether the dictation key can be seen: while it can't, a notice says where to allow it.
    private func noteDictationKeys(_ mode: HotkeyTap.Mode) {
        guard mode == .off else {
            notice.withdraw(NoticeTopic.dictationKey)
            return
        }

        let key = settings?.dictationKeyLabel ?? "Fn"
        tell(
            "Voice Assistant can't see the \(key) key yet: allow it in System Settings › Privacy & Security › "
                + "Accessibility.",
            topic: NoticeTopic.dictationKey)
    }

    /// The tap the permissions allow: active with the right to post events, else listen-only with Input Monitoring.
    private func allowedTap() -> HotkeyTap.Mode {
        let permissions = Permissions()
        if permissions.status(.postEvents) == .granted {
            return .active
        }

        return permissions.status(.inputMonitoring) == .granted ? .listenOnly : .off
    }

    private func stopInput() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        keys?.stop()
        for hotkey in hotkeys {
            hotkey.unregister()
        }

        hotkeys = []
        otherApp?.stop()
    }

    // MARK: Telling

    /// ThumbFree uses Fn too: with both listening, every dictation would be typed twice. It watches for Voice Assistant
    /// the same way. The warning is in force while both run, and `thumbFreeChanged` says when that changes.
    private func warnIfThumbFreeRuns() {
        if otherApp == nil {
            let other = OtherApp(otherThan: Bundle.main.bundleIdentifier ?? VoiceAssistantApp.bundleIdentifier)
            other?.onChange = { [weak self] _ in MainActor.assumeIsolated { self?.warnIfThumbFreeRuns() } }
            other?.start()
            otherApp = other
        }

        let running = otherApp?.isRunning == true
        let sameKey = settings?.pushToTalk == true && settings?.dictationKey == .fn
        let clash = running && sameKey
        guard clash != thumbFreeRunsToo else { return }
        thumbFreeRunsToo = clash
        if clash {
            Log.warn("ThumbFree is running too")
            host?.report(.warning, Self.thumbFreeNote)
            notice.send(Self.thumbFreeNote, topic: NoticeTopic.thumbFree)
        } else {
            Log.info("ThumbFree isn't running any more")
            notice.withdraw(NoticeTopic.thumbFree)
        }

        thumbFreeChanged.send(clash)
    }

    /// A notice for the UI to show (Windows' tray balloon), and the log; with a `topic`, it stays in force until it's
    /// withdrawn.
    private func tell(_ message: String, topic: String? = nil) {
        Log.warn("notice: \(message)")
        notice.send(message, topic: topic)
    }

    /// The desktop opens apps, reads windows and types through Accessibility, which Windows needs no permission for:
    /// until macOS allows it, commands can't act, so this says where it's allowed, and withdraws it once it is. (The
    /// desktop asks again at each call, so allowing it works without a restart.)
    private func checkDesktopPermissions() {
        let missing = missingDesktopPermissions
        guard missing.isEmpty != desktopAllowed else { return }
        desktopAllowed = missing.isEmpty
        if desktopAllowed {
            Log.info("desktop permissions given")
            notice.withdraw(NoticeTopic.desktop)
        } else {
            Log.warn("desktop permissions missing: \(missing.map(\.rawValue).joined(separator: ", "))")
            host?.report(.warning, Self.desktopNotAllowedNote)
            tell(Self.desktopNotAllowedNote, topic: NoticeTopic.desktop)
        }
    }

    private func restarted(_ started: Bool) {
        if started {
            NSApp.terminate(nil)
        } else {
            Log.warn("restart failed")
            tell("Couldn't restart. Quit from the menu bar and start Voice Assistant again.")
        }
    }

    @objc private func showRequestedByAnotherCopy(_ notification: Notification) {
        showRequested.send(())
    }

    // MARK: The self-test

    private func runSelfTest(_ files: LaunchOptions.SelfTestFiles) {
        Log.start(in: paths.logs)
        Log.info("self-test \(Self.version)")
        let settings = AppSettings.loadOrCreate(from: paths.settingsFile)
        insertMethod.value = settings.insertMethod
        guard let desktop = parts.desktopParts(insertMethod: insertMethod) else {
            let message = "!! This build has no desktop, so the self-test can't run.\n"
            try? Data(message.utf8).write(to: URL(fileURLWithPath: files.output))
            NSApp.terminate(nil)
            return
        }

        reader.startWaking()
        let paths = self.paths
        let hostParts = parts.hostParts(settings, paths, desktop: desktop)
        let platform = SelfTestPlatform.mac(insertMethod, desktop: desktop)
        Task { @MainActor in
            await SelfTest.run(
                scriptPath: files.script, outputPath: files.output, settings: settings, paths: paths,
                parts: hostParts, platform: platform)
            NSApp.terminate(nil)
        }
    }

    // MARK: The menu until the UI lands

    private static func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice Assistant") {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "VA"
        }

        item.menu = menu()
        return item
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

    /// Something failed before the menu existed: with no menu there's no way to quit it, so it says so and quits.
    private static func failedToStart(_ error: Error, logs: String) {
        Log.error("start failed: \(Log.kind(of: error))")
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        let alert = NSAlert()
        alert.messageText = "Voice Assistant couldn't start"
        alert.informativeText = "\(error.localizedDescription)\n\nIts log has the details: \(logs)"
        alert.runModal()
        exit(1)
    }
}

/// The dictation keys' Quartz event tap, which also tells the app about each Esc press (Windows'
/// `DictationKeyHook.EscapePressed`), so Esc stops the AI brain: before the keys see that Esc, so the app still knows
/// whether it cancels a recording. Esc keys this app posts don't count.
final class EscapeWatchingSource: HotkeyTap.EventSource {
    private let inner: HotkeyTap.EventSource
    private let escape: @Sendable () -> Void

    init(_ inner: HotkeyTap.EventSource, escape: @escaping @Sendable () -> Void) {
        self.inner = inner
        self.escape = escape
    }

    func start(_ handler: @escaping @Sendable (HotkeyTap.Event) -> Bool) -> HotkeyTap.Mode {
        let escape = self.escape
        return inner.start { event in
            if !event.fromThisApp, let change = event.keyChange, change.key == .escape, change.down {
                escape()
            }

            return handler(event)
        }
    }

    func stop() {
        inner.stop()
    }
}
