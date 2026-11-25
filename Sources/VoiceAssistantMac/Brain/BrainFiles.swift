import Darwin
import Foundation
import ThumbFreeCore
import ThumbFreeSpeech

/// The AI brain's files (windows-voice-assistant src/VoiceAssistant.App/Brain/BrainFiles.cs): llama.cpp's server for
/// Apple silicon, which runs the model on the graphics chip with Metal, and the Qwen3 4B Instruct model. Downloaded
/// once, on request, from their official releases by ThumbFree's model store, which resumes a download that stopped and
/// checks each file's SHA-256 before giving it its name. Paths in settings override the downloaded ones; files there
/// are never downloaded over or deleted.
public struct BrainFiles: Sendable {
    public static let llamaBuild = "b12483"
    public static let modelName = "Qwen3 4B"

    private static let releases = "https://github.com/ggml-org/llama.cpp/releases/download/\(llamaBuild)"

    /// llama.cpp's build for Apple silicon (macOS 13.3 or later): llama-server and the libraries it loads from its own
    /// folder, under "llama-b12483/", with the Metal shaders built into libggml-metal. Its programs carry the linker's
    /// ad-hoc signature, which is all Apple silicon needs to run them.
    static let pinnedServer = ModelFile(
        "llama-\(llamaBuild)-bin-macos-arm64.tar.gz", "\(releases)/llama-\(llamaBuild)-bin-macos-arm64.tar.gz",
        "a7e77443b598e497e43bfc9dcb993a355a217df9a2eda99c3d421356ab70c1a9", 17_212_020)

    /// llama.cpp's build for Intel Macs (macOS 13.3 or later), laid out the same way: the processor only, with no Metal
    /// library, and unsigned, which Intel Macs allow. The brain bench measures it; Intel Macs aren't offered the brain
    /// until it has been measured (`unavailableReason`).
    static let pinnedIntelServer = ModelFile(
        "llama-\(llamaBuild)-bin-macos-x64.tar.gz", "\(releases)/llama-\(llamaBuild)-bin-macos-x64.tar.gz",
        "d030a790cb868c15066b1f463a667f3fcb3c807a7c0427d64a49b1b6980ce723", 12_971_992)

    /// Windows' model. Q4_0 is the format llama.cpp's Adreno code is tuned for (ai-brain.md, spike 2); on Metal, Q4_K_M
    /// is measured against it before the first release (docs/design.md). Pinned to the commit of unsloth's repository
    /// that has this file, so a new upload there can't make a finished 2.4 GB download fail its check (Windows still
    /// follows main).
    static let pinnedModel = ModelFile(
        "Qwen3-4B-Instruct-2507-Q4_0.gguf",
        "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/a06e946bb6b655725eafa393f4a9745d460374c9/"
            + "Qwen3-4B-Instruct-2507-Q4_0.gguf",
        "e0ba675d86ab277c61701c6793659b2ae801d95e3be791464c321e6fbf613be2", 2_375_773_280)

    static let chosenFileMissing = "A file chosen in settings.json (brainServerPath or brainModelPath) doesn't exist."

    /// What a download fetches: llama.cpp's archive and the model. The integration test uses a small model instead.
    struct Downloads: Sendable {
        var server: ModelFile
        var model: ModelFile

        /// This Mac's llama.cpp build (by its processor, even when this app runs under Rosetta) and the model.
        static var pinned: Downloads {
            Downloads(
                server: BrainFiles.isAppleSilicon ? BrainFiles.pinnedServer : BrainFiles.pinnedIntelServer,
                model: BrainFiles.pinnedModel)
        }
    }

    /// Where downloads go: ~/Library/Application Support/VoiceAssistant/brain, or settings.json's `brainFolder`.
    public let folder: String

    /// llama-server: the downloaded one, or settings.json's `brainServerPath`.
    public let serverPath: String

    /// The model: the downloaded one, or settings.json's `brainModelPath` (the prompt is measured with Qwen3 4B).
    public let modelPath: String

    let serverChosen: Bool
    let modelChosen: Bool
    let downloads: Downloads

    /// The downloads' session (tests); nil uses the model store's.
    let session: URLSession?

    /// Settings' `brainFolder`, `brainServerPath` and `brainModelPath`: nil or blank for the defaults. A "~" at the
    /// start is the home folder (Windows expands %VARIABLES% instead).
    public init(folder: String? = nil, serverPath: String? = nil, modelPath: String? = nil) {
        self.init(folder: folder, serverPath: serverPath, modelPath: modelPath, downloads: .pinned)
    }

    init(folder: String?, serverPath: String?, modelPath: String?, downloads: Downloads, session: URLSession? = nil) {
        let place = Self.setting(folder) ?? Self.defaultFolder
        let server = Self.setting(serverPath)
        let model = Self.setting(modelPath)
        self.folder = place
        serverChosen = server != nil
        modelChosen = model != nil
        self.serverPath = server ?? Self.combine(place, "llama.cpp-\(Self.llamaBuild)/llama-server")
        self.modelPath = model ?? Self.combine(place, downloads.model.path)
        self.downloads = downloads
        self.session = session
    }

    /// ~/Library/Application Support/VoiceAssistant/brain.
    public static var defaultFolder: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
            ?? combine(NSHomeDirectory(), "Library/Application Support")
        return combine(support, "VoiceAssistant/brain")
    }

    /// Both files are there.
    public var isInstalled: Bool { Self.isFile(serverPath) && Self.isFile(modelPath) }

    /// Bytes a download would fetch now: what's missing at the default paths.
    public var missingBytes: Int64 {
        (!serverChosen && !Self.isFile(serverPath) ? downloads.server.bytes : 0)
            + (!modelChosen && !Self.isFile(modelPath) ? downloads.model.bytes : 0)
    }

    /// Why this Mac can't run the brain, or nil if it can.
    public var unavailableReason: String? {
        Self.reasonUnavailable(
            appleSilicon: Self.isAppleSilicon, macOS: ProcessInfo.processInfo.operatingSystemVersion,
            serverChosen: serverChosen)
    }

    /// Apple silicon first: whether Intel Macs run the brain usefully is measured before it's offered there
    /// (docs/design.md). The downloaded server needs macOS 13.3 or later; a server chosen in settings may not.
    static func reasonUnavailable(appleSilicon: Bool, macOS: OperatingSystemVersion, serverChosen: Bool) -> String? {
        if !appleSilicon {
            return "The AI brain needs a Mac with Apple silicon. It isn't available on Intel Macs yet."
        }

        if !serverChosen && (macOS.majorVersion, macOS.minorVersion) < (13, 3) {
            return "The AI brain needs macOS 13.3 or later."
        }

        return nil
    }

    /// Apple silicon, even when this app runs under Rosetta: the server runs natively all the same.
    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    /// Downloads (resuming) and checks what's missing, and unpacks the server. Progress is (bytes so far, bytes in
    /// all). Throws `BrainError` or the model store's `DownloadError`, whose messages can be shown as they are, or
    /// `CancellationError`.
    func download(progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        if (serverChosen && !Self.isFile(serverPath)) || (modelChosen && !Self.isFile(modelPath)) {
            throw BrainError(Self.chosenFileMissing)
        }

        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // Requests say they come from Jarvis, not ThumbFree (the store's default). The store's
        // removeLeftovers(keeping:) is never used on this folder: it would delete the unpacked llama.cpp.
        let store = ModelStore(primaryFolder: folder, userAgent: "VoiceAssistant", session: session)
        let total = missingBytes
        // Only ever the default paths, so a chosen file or its folder is never written over or deleted.
        var done: Int64 = 0
        if !serverChosen && !Self.isFile(serverPath) {
            let before = done
            try await store.download(downloads.server) { progress(before + $0.done, total) }
            try await unpackServer()
            done += downloads.server.bytes
        }

        if !modelChosen && !Self.isFile(modelPath) {
            let before = done
            try await store.download(downloads.model) { progress(before + $0.done, total) }
        }
    }

    /// Unpacks llama.cpp's archive into the server's own folder ("llama.cpp-b12483") with macOS's tar, which keeps the
    /// programs' executable bits and the libraries' links, then deletes the archive. Only that folder is ever replaced.
    private func unpackServer() async throws {
        let archive = Self.combine(folder, downloads.server.path)
        let target = (serverPath as NSString).deletingLastPathComponent
        let unpacking = target + ".unpacking"
        let files = FileManager.default
        try? files.removeItem(atPath: unpacking)
        try files.createDirectory(atPath: unpacking, withIntermediateDirectories: true)
        let status = try await Self.run(
            "/usr/bin/tar", ["-x", "-f", archive, "-C", unpacking, "--strip-components", "1"])
        guard status == 0, files.isExecutableFile(atPath: Self.combine(unpacking, "llama-server")) else {
            try? files.removeItem(atPath: unpacking)
            throw BrainError("The llama.cpp download couldn't be unpacked. Try again.")
        }

        if files.fileExists(atPath: target) {
            try files.removeItem(atPath: target)
        }

        try files.moveItem(atPath: unpacking, toPath: target)
        try? files.removeItem(atPath: archive)
    }

    /// Runs a tool to its end, with nothing in or out; its exit status.
    static func run(_ tool: String, _ arguments: [String]) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }

        withExtendedLifetime(process) {}
        return status
    }

    /// `File.Exists`: a file, not a folder.
    static func isFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    static func combine(_ folder: String, _ name: String) -> String {
        (folder as NSString).appendingPathComponent(name)
    }

    /// A path from settings: trimmed, with "~" expanded; nil when blank.
    private static func setting(_ value: String?) -> String? {
        guard let value, !DotNet.isNullOrWhiteSpace(value) else { return nil }
        return (DotNet.trim(value) as NSString).expandingTildeInPath
    }
}
