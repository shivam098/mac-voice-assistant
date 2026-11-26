import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import ThumbFreeCore
import ThumbFreeMac
import VoiceAssistantBoard
import VoiceAssistantCore

/// What the self-test reads of the Mac besides the desktop: the focused element's kind and text, which it only ever
/// measures and hashes; the clipboard's fingerprint; the insertion method it switches; and the permissions it needs.
public struct SelfTestPlatform: Sendable {
    /// The focused element's role ("AXTextArea") and text; "(timeout)" or "(error …)" without text when it can't be
    /// read.
    public var focusedText: @Sendable () -> (kind: String, text: String)

    /// The clipboard's formats, a hash of its text and its length, never the text.
    public var clipboardFingerprint: @Sendable () -> String

    /// Switches the desktop's insertion method ("Paste" or "Type").
    public var setInsertMethod: @Sendable (String) -> Void

    /// The permissions the desktop needs that this process hasn't got ("accessibility", "postEvents"); none to run.
    public var missingPermissions: @Sendable () -> [String]

    public init(
        focusedText: @escaping @Sendable () -> (kind: String, text: String),
        clipboardFingerprint: @escaping @Sendable () -> String,
        setInsertMethod: @escaping @Sendable (String) -> Void,
        missingPermissions: @escaping @Sendable () -> [String] = { [] }
    ) {
        self.focusedText = focusedText
        self.clipboardFingerprint = clipboardFingerprint
        self.setInsertMethod = setInsertMethod
        self.missingPermissions = missingPermissions
    }

    /// This Mac: the Accessibility API, the general pasteboard, the insertion method the desktop reads, and the
    /// permissions the desktop is missing (as macOS counts them, those of the terminal or runner that started the app,
    /// when it's started directly).
    static func mac(_ insertMethod: Locked<String>, desktop: DesktopParts) -> SelfTestPlatform {
        let missing = desktop.missingPermissions
        return SelfTestPlatform(
            focusedText: { FocusedText.read() },
            clipboardFingerprint: {
                Thread.isMainThread
                    ? SelfTest.pasteboardFingerprint()
                    : DispatchQueue.main.sync(execute: SelfTest.pasteboardFingerprint)
            },
            setInsertMethod: { insertMethod.value = $0 },
            missingPermissions: { missing?().map(\.rawValue) ?? [] })
    }
}

/// Runs a script of transcripts through the real controller and desktop, without the microphone or the models, so
/// desktop flows can be checked end to end (windows-voice-assistant `SelfTest`, which its NavigationLab and EditingLab
/// acceptance tests run): `VoiceAssistant --self-test <script> [<output>]`. docs/self-test.md has the whole story: the
/// labs, `scripts/self-test.sh` and the Self-test workflow. Script lines:
///
///     listen                 start listening (standby, or command mode without the wake word)
///     say: <transcript>      as if Whisper heard it (confidence 0.9)
///     ptt: <transcript>      as if dictated with the dictation key
///     wait <ms>
///     fg                     record the bundle identifier of the app with the keyboard focus
///     read                   record the focused element's role, text length and hash (not its text)
///     expect: <text>         PASS/FAIL: the focused element's text contains the phrase (\n = line break)
///     expectvalue: <text>    PASS/FAIL: the focused element's whole text is this (\n = line break)
///     expecttitle: <text>    PASS/FAIL: the front window's title contains the phrase (the title isn't written)
///     expectfocus: <name>    PASS/FAIL: the focused control's accessible name contains the phrase
///     expectboard: <list> <text>  PASS/FAIL: the self-test's own idea board has that note in that list
///     braindownload          download the AI brain's missing files and wait (records ok or failed only)
///     brainwait <seconds>    load the AI brain if needed and wait until it's ready; records its state
///     insert Paste|Type      switch the insertion method
///     stoponfail             stop at the first FAIL (use before steps that type)
///     clipboard              record a fingerprint of the clipboard (formats, hash, length), not its text
///     # comment
///
/// The output has a line "> <line>" for each script line, then what came of it, indented by three spaces: status
/// lines ("[Command] Success: Typed."), "PASS: …" and "FAIL: …", and what `fg`, `read` and `clipboard` record. A line
/// starting "!!" says the run stopped: a failed check after `stoponfail`, an error, or missing permissions (then
/// nothing runs). It's written as the run goes, so one that hangs leaves what it did. It never holds user text, window
/// titles or clipboard contents: text in “quotes” in status lines is left out. Windows' `typing <chunk> <delay>` tunes
/// its own key typing; the Mac reads it and does nothing. The pill and the number badges aren't shown until the app's
/// UI lands.
public enum SelfTest {
    /// C#'s `FormatException`, for a number the script doesn't give as one.
    struct FormatException: Error, LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    /// Runs the script at `scriptPath` and writes what happened to `outputPath`.
    public static func run(
        scriptPath: String,
        outputPath: String,
        settings: AppSettings,
        paths: AppPaths,
        parts: HostParts,
        platform: SelfTestPlatform,
        post: @escaping AssistantHost.Post = AssistantHost.postToMain
    ) async {
        let output = Output(path: outputPath)
        let missing = platform.missingPermissions()
        if !missing.isEmpty {
            // Without them the desktop can't read or type, and keys would go nowhere.
            output.add(
                "!! missing permissions: \(missing.joined(separator: ", ")). Allow the app, or the terminal that "
                    + "starts it, in System Settings › Privacy & Security › Accessibility. Nothing was run.")
            output.finish()
            return
        }

        // An idea board in memory: self-tests never touch the user's notes.
        guard let board = try? BoardStore(path: nil) else {
            output.finish()
            return
        }

        let host = AssistantHost(
            settings: settings, paths: paths, parts: parts, board: board, persistMemory: false, post: post)
        host.status.subscribe { status in
            output.add("   [\(name(status.mode))] \(name(status.kind)): \(redact(status.message))")
        }

        host.choicesChanged.subscribe { badges in output.add(choicesLine(badges)) }
        await host.startForSelfTest()
        do {
            var stopOnFail = false
            for raw in try lines(scriptPath) {
                let line = DotNet.trim(raw)
                if line.isEmpty || line.hasPrefix("#") {
                    continue
                }

                output.add("> \(line)")
                if stopOnFail && output.text.contains("   FAIL:") {
                    // A failed check means the expected window or box isn't in front: typing on could go elsewhere.
                    output.add("!! stopped after a failed check")
                    break
                }

                if line == "stoponfail" {
                    stopOnFail = true
                } else {
                    try await step(line, host, board, platform, output)
                }

                try await Task.sleep(nanoseconds: 400_000_000)
            }

            // Lets the status lines still being posted land.
            try await Task.sleep(nanoseconds: 500_000_000)
        } catch {
            output.add("!! \(String(describing: type(of: error))): \(AssistantHost.message(error))")
        }

        output.finish()
        await host.shutdown()
    }

    /// One script line other than `stoponfail`.
    private static func step(
        _ line: String, _ host: AssistantHost, _ board: BoardStore, _ platform: SelfTestPlatform, _ output: Output
    ) async throws {
        if line == "listen" {
            try await host.runOnQueue { _ = host.controller.setListening(true) }
        } else if line.hasPrefix("say:") {
            let text = rest(line, "say:")
            try await host.runOnQueue { try await host.controller.handleTranscript(text, 0.9) }
        } else if line.hasPrefix("ptt:") {
            let text = rest(line, "ptt:")
            try await host.runOnQueue { try host.controller.insertDictation(text) }
        } else if line.hasPrefix("wait ") {
            let milliseconds = try number(rest(line, "wait "))
            try await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
        } else if line.hasPrefix("typing ") {
            // Windows' typing speed; the Mac's typing has no such setting.
            for part in rest(line, "typing ").split(separator: " ") {
                _ = try number(String(part))
            }
        } else if line.hasPrefix("insert ") {
            platform.setInsertMethod(rest(line, "insert "))
        } else if line == "clipboard" {
            output.add("   clipboard fingerprint: \(platform.clipboardFingerprint())")
        } else if line == "fg" {
            // The app only: window titles can hold the names of the user's documents and pages.
            let front = try await onQueue(host, "") { host.parts.desktop.foregroundWindow()?.processName ?? "" }
            output.add("   foreground: \(front)")
        } else if line == "braindownload" {
            // Downloads what's missing of the AI brain (resuming) and waits; records only whether it worked: its files
            // are all here and the download didn't fail. A model that downloaded but couldn't start did download.
            host.startBrainDownload()
            try await Task.sleep(nanoseconds: 500_000_000)
            while host.brainDownloadProgress != nil {
                try await Task.sleep(nanoseconds: 500_000_000)
            }

            let installed = host.brain.map { $0.missingBytes == 0 } ?? false
            let ok = installed && host.brainDownloadError == nil
            output.add("   brain download: \(ok ? "ok" : "failed")")
        } else if line.hasPrefix("brainwait ") {
            let seconds = try number(rest(line, "brainwait "))
            let deadline = Date().addingTimeInterval(TimeInterval(seconds))
            host.brain?.warmUp()
            while let brain = host.brain, ![.ready, .failed, .notInstalled].contains(brain.availability),
                  Date() < deadline {
                try await Task.sleep(nanoseconds: 250_000_000)
            }

            let state = host.brain.map { name($0.availability) } ?? "off"
            output.add("   brain: \(state)")
        } else if line == "read" {
            let focused = platform.focusedText()
            output.add("   focused: \(focused.kind) len=\(focused.text.utf16.count) hash=\(hash(focused.text))")
        } else if line.hasPrefix("expectfocus:") {
            // The accessible name of the focused control: a label from the test page.
            let expected = rest(line, "expectfocus:")
            let focus = try await onQueue(host, "") { host.parts.desktop.describeFocus()?.name ?? "" }
            let pass = containsIgnoringCase(focus, expected)
            output.add(
                "   \(pass ? "PASS" : "FAIL"): focused control \(pass ? "has" : "does not have") the expected name")
        } else if line.hasPrefix("expecttitle:") {
            // PASS or FAIL only: the title itself is never written.
            let expected = rest(line, "expecttitle:")
            let title = try await onQueue(host, "") { host.parts.desktop.foregroundWindow()?.title ?? "" }
            let pass = containsIgnoringCase(title, expected)
            output.add(
                "   \(pass ? "PASS" : "FAIL"): foreground title \(pass ? "contains" : "does not contain") the expected "
                    + "phrase")
        } else if line.hasPrefix("expectboard:") {
            // "expectboard: Todo Draft a reply": the self-test's board has that note in that list.
            let parts = rest(line, "expectboard:").split(separator: " ", maxSplits: 1).map(String.init)
            let list = parts.first.flatMap(boardList)
            let pass = parts.count == 2 && list != nil
                && board.items.contains { $0.list == list && DotNet.ordinalEquals($0.text, parts[1]) }
            output.add(
                "   \(pass ? "PASS" : "FAIL"): board \(pass ? "has" : "does not have") the expected note "
                    + "(notes=\(board.items.count))")
        } else if line.hasPrefix("expect:") {
            // Only whether the script's own phrase is there, never the field's other text. A Mac text box's line break
            // is "\n" (Windows' is "\r").
            let expected = DotNet.replace(rest(line, "expect:"), "\\n", "\n")
            let actual = platform.focusedText().text
            let pass = DotNet.contains(actual, expected)
            output.add(
                "   \(pass ? "PASS" : "FAIL"): focused text \(pass ? "contains" : "does not contain") the expected "
                    + "phrase (field len=\(actual.utf16.count))")
        } else if line.hasPrefix("expectvalue:") {
            // The whole field is the script's text; for the test's own window only.
            let expected = DotNet.replace(rest(line, "expectvalue:"), "\\n", "\n")
            let text = platform.focusedText().text
            let actual = DotNet.trimEnd(DotNet.replace(DotNet.replace(text, "\r\n", "\n"), "\r", "\n"))
            let pass = DotNet.ordinalEquals(actual, expected)
            output.add(
                "   \(pass ? "PASS" : "FAIL"): focused text \(pass ? "equals" : "does not equal") the expected text "
                    + "(field len=\(actual.utf16.count), expected len=\(expected.utf16.count))")
        }
    }

    /// `work`'s result, run on the host's queue between the controller's calls, as the desktop expects; `fallback` if
    /// the queue had stopped.
    private static func onQueue<T: Sendable>(
        _ host: AssistantHost, _ fallback: T, _ work: @escaping @Sendable () -> T
    ) async throws -> T {
        let result = Locked<T?>(nil)
        try await host.runOnQueue { result.value = work() }
        return result.value ?? fallback
    }

    /// The text after a line's command, trimmed.
    private static func rest(_ line: String, _ command: String) -> String {
        DotNet.trim(String(line.dropFirst(command.count)))
    }

    /// A whole number, as C#'s `int.Parse` reads it.
    private static func number(_ text: String) throws -> Int {
        guard let value = Int(DotNet.trim(text)) else {
            throw FormatException(message: "The input string '\(text)' was not in a correct format.")
        }

        return value
    }

    /// The script's lines, read as C#'s `File.ReadAllLines` reads them.
    private static func lines(_ path: String) throws -> [String] {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        return DotNet.lines(NetJSON.text(Array(bytes)))
    }

    /// A list by its name in any case, or its number, as C#'s `Enum.TryParse` takes it.
    private static func boardList(_ name: String) -> BoardList? {
        if let number = Int(name) {
            return BoardList.allCases.indices.contains(number) ? BoardList.allCases[number] : nil
        }

        return BoardList.allCases.first { DotNet.equalsOrdinalIgnoreCase($0.rawValue, name) }
    }

    /// Where the numbers are, never what they label: enough to tell one button reported twice from two buttons.
    static func choicesLine(_ badges: [ChoiceBadge]?) -> String {
        guard let badges, !badges.isEmpty else { return "   choices shown: 0" }
        let places = badges.map { badge in
            let rect = badge.rect
            return "\(f0(rect.x)),\(f0(rect.y)) \(f0(rect.width))x\(f0(rect.height))"
        }

        return "   choices shown: \(badges.count) at " + places.joined(separator: "; ")
    }

    /// Names, titles and heard text appear in “quotes” in status lines; they're kept out of the output.
    static func redact(_ message: String) -> String { quoted.replace(message, "“…”") }

    /// The first 12 hex digits of the text's SHA-256 (UTF-8), as C#'s `Convert.ToHexString` writes them.
    static func hash(_ text: String) -> String {
        String(SHA256.hash(data: Data(text.utf8)).map { String(format: "%02X", $0) }.joined().prefix(12))
    }

    /// The general pasteboard's formats (the first 6), its text's hash and length. Main thread.
    static func pasteboardFingerprint() -> String {
        let pasteboard = NSPasteboard.general
        let types = pasteboard.types ?? []
        let formats = types.isEmpty ? "(empty)" : types.prefix(6).map { $0.rawValue }.joined(separator: ",")
        let text = pasteboard.string(forType: .string) ?? ""
        return "formats=[\(formats)] textHash=\(hash(text)) len=\(text.utf16.count)"
    }

    /// The names C#'s enums print.
    static func name(_ mode: InteractionMode) -> String {
        switch mode {
        case .paused: return "Paused"
        case .standby: return "Standby"
        case .command: return "Command"
        case .dictation: return "Dictation"
        }
    }

    static func name(_ kind: StatusKind) -> String {
        switch kind {
        case .info: return "Info"
        case .success: return "Success"
        case .warning: return "Warning"
        case .error: return "Error"
        }
    }

    static func name(_ availability: BrainAvailability) -> String {
        switch availability {
        case .off: return "Off"
        case .notInstalled: return "NotInstalled"
        case .sleeping: return "Sleeping"
        case .loading: return "Loading"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }

    private static let quoted = NetRegex("“[^”]*”")

    /// `string.Contains(value, StringComparison.OrdinalIgnoreCase)`.
    private static func containsIgnoringCase(_ text: String, _ value: String) -> Bool {
        DotNet.contains(DotNet.upperInvariant(text), DotNet.upperInvariant(value))
    }

    /// C#'s `{x:F0}`.
    private static func f0(_ value: Double) -> String { String(format: "%.0f", value) }

    /// The output as it grows, from the script and from the host's events. Each line goes to the file as it comes, so
    /// a run that hangs or stops early leaves what it did; at the end the whole text is written again, as Windows
    /// writes it.
    final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private let path: String?
        private var lines = ""
        private var file: FileHandle?

        /// - Parameter path: The output file, started empty; nil keeps the output in memory only.
        init(path: String? = nil) {
            self.path = path
            if let path, FileManager.default.createFile(atPath: path, contents: nil) {
                file = FileHandle(forWritingAtPath: path)
            }
        }

        func add(_ line: String) {
            lock.withLock {
                lines += line + "\n"
                try? file?.write(contentsOf: Data((line + "\n").utf8))
            }
        }

        var text: String { lock.withLock { lines } }

        /// Writes the whole output to the file once more; lines added after it stay in memory only.
        func finish() {
            let (text, handle): (String, FileHandle?) = lock.withLock {
                defer { file = nil }
                return (lines, file)
            }

            try? handle?.close()
            guard let path else { return }
            do {
                try Data(text.utf8).write(to: URL(fileURLWithPath: path))
            } catch {
                Log.error("self-test output not written: \(Log.kind(of: error))")
            }
        }
    }
}

/// The element with the keyboard focus through the Accessibility API: its role and text, for the self-test, which only
/// measures and hashes the text. A password box's text is never read.
enum FocusedText {
    /// Waits 2 s at most, as Windows does.
    static func read() -> (kind: String, text: String) {
        let result = Locked<(kind: String, text: String)?>(nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            result.value = readNow()
            done.signal()
        }

        guard done.wait(timeout: .now() + 2) == .success, let read = result.value else { return ("(timeout)", "") }
        return read
    }

    private static func readNow() -> (kind: String, text: String) {
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused)
        guard status == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return ("(error AXError \(status.rawValue))", "")
        }

        let element = unsafeBitCast(focused, to: AXUIElement.self)
        let role = string(kAXRoleAttribute, of: element) ?? "(unknown)"
        if string(kAXSubroleAttribute, of: element) == kAXSecureTextFieldSubrole {
            return (role, "")
        }

        return (role, string(kAXValueAttribute, of: element) ?? "")
    }

    private static func string(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
