import Foundation
import ThumbFreeCore
import ThumbFreeSpeech

/// Downloads the speech models on first use, each checked against its SHA-256 before it's used (windows-voice-assistant
/// `ModelDownloader`): the same files, addresses and hashes as Windows. Downloads go through ThumbFreeSpeech's
/// `ModelStore` into Voice Assistant's models folder, and a model ThumbFree for Mac already has is used from its folder
/// (read only) instead of being downloaded again; ThumbFree reads Voice Assistant's folder the same way. The store
/// also resumes a dropped download, tries each file up to 5 times, checks the free space first and remembers which
/// files it verified (see `ModelStore`).
public struct ModelDownloader: Sendable {
    private static let whisperCpp = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"

    /// OpenAI Whisper small.en (MIT), quantized to 8 bits, from whisper.cpp's models on Hugging Face: "Hey Jarvis" and
    /// commands. The hashes are the Hugging Face LFS object ids, as on Windows; the sizes are the files'.
    public static let smallEnglish = ModelFile(
        "ggml-small.en-q8_0.bin", whisperCpp + "ggml-small.en-q8_0.bin",
        "67a179f608ea6114bd3fdb9060e762b588a3fb3bd00c4387971be4d177958067", 264_477_561)

    /// Whisper base.en, quantized to 8 bits.
    public static let baseEnglishQ8 = ModelFile(
        "ggml-base.en-q8_0.bin", whisperCpp + "ggml-base.en-q8_0.bin",
        "a4d4a0768075e13cfd7e19df3ae2dbc4a68d37d36a7dad45e8410c9a34f8c87e", 81_781_811)

    /// Whisper base.en.
    public static let baseEnglish = ModelFile(
        "ggml-base.en.bin", whisperCpp + "ggml-base.en.bin",
        "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002", 147_964_211)

    /// Every model it can download, in Windows' order: the English models above, then Silero and the two Hindi +
    /// English models (Oriserve's, from windows-voice-assistant's releases), which are ThumbFreeCore's own catalog
    /// entries: ThumbFree uses the same files, addresses and hashes.
    public static let catalog: [ModelFile] = [
        smallEnglish, baseEnglishQ8, baseEnglish, ModelCatalog.vad, ModelCatalog.hinglish.files[0],
        ModelCatalog.hinglishAccurate.files[0],
    ]

    /// Whether `name` is a model it can download, in any case (`CanDownload`).
    public static func canDownload(_ name: String) -> Bool { file(named: name, in: catalog) != nil }

    public let store: ModelStore

    private let catalog: [ModelFile]

    /// What its downloads say they come from (their User-Agent), rather than ThumbFree's store's own name.
    public static let userAgent = "VoiceAssistant"

    /// Downloads into `paths.models`, and finds models in `paths.sharedModels` too. ModelStore's `removeLeftovers`
    /// is never called for this folder; anything that does must keep this catalog's paths, never ThumbFree's.
    public init(paths: AppPaths, session: URLSession? = nil) {
        self.init(
            store: ModelStore(
                primaryFolder: paths.models, sharedFolders: paths.sharedModels, userAgent: Self.userAgent,
                session: session))
    }

    /// - Parameter catalog: The models it can download; tests use their own.
    public init(store: ModelStore, catalog: [ModelFile] = ModelDownloader.catalog) {
        self.store = store
        self.catalog = catalog
    }

    /// The model called `name` (a file name such as settings.json's `modelFile`, in any case).
    public func file(named name: String) -> ModelFile? { Self.file(named: name, in: catalog) }

    /// Where the model is: Voice Assistant's models folder first, then ThumbFree's; nil if it isn't on this Mac.
    public func path(of name: String) -> String? { file(named: name).flatMap { store.pathOf($0) } }

    public func isInstalled(_ name: String) -> Bool { path(of: name) != nil }

    /// Downloads the model called `name` unless it's here and intact (`DownloadAsync`), reporting whole percents, each
    /// once. Throws a `DownloadError` people can read (one for a name it doesn't know), or `CancellationError`.
    public func download(_ name: String, progress: @escaping @Sendable (Int) -> Void) async throws {
        guard let file = file(named: name) else {
            throw DownloadError("Voice Assistant can't download \(name): it isn't one of its models.")
        }

        let last = LastPercent()
        try await store.download(file) { bytes in
            let percent = bytes.total > 0 ? Int(bytes.done * 100 / bytes.total) : 0
            if last.change(to: percent) {
                progress(percent)
            }
        }
    }

    /// The catalog's file called `name`, compared as `StringComparer.OrdinalIgnoreCase` does.
    private static func file(named name: String, in catalog: [ModelFile]) -> ModelFile? {
        let wanted = DotNet.ordinalIgnoreCase(name)
        return catalog.first { DotNet.ordinalIgnoreCase($0.name) == wanted }
    }

    /// The percent last reported, as C#'s `lastPercent`; the store reports from its own threads.
    private final class LastPercent: @unchecked Sendable {
        private let lock = NSLock()
        private var value = -1

        /// True when `percent` differs from the last one, which it then becomes.
        func change(to percent: Int) -> Bool {
            lock.withLock {
                if value == percent {
                    return false
                }

                value = percent
                return true
            }
        }
    }
}
