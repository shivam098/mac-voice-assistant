import Foundation

/// What the AI brain is doing, for Settings and the menu (Windows' AI brain section shows the same states).
public enum BrainStatus: Hashable, Sendable {
    /// This Mac can't run it. The reason is a sentence to show as it is.
    case unavailable(String)

    /// Its files aren't on this Mac: `BrainFiles.missingBytes` to download, or, when that's 0, files chosen in
    /// settings.json (`brainServerPath`, `brainModelPath`) that aren't there.
    case notInstalled

    /// Downloading: bytes so far and in all.
    case downloading(received: Int64, total: Int64)

    /// Downloaded and checked, not loaded yet: it loads when it's next asked for something.
    case installed

    /// llama-server is loading the model.
    case starting

    /// Loaded and answering.
    case ready

    /// Unloaded after `LlamaBrain.keepLoaded` unused: it loads again when it's next asked for something.
    case unloaded

    /// The download or the server failed. The reason is a sentence to show as it is: the next download carries on
    /// where this one stopped, and the next request starts the server again.
    case failed(String)
}

/// Why the AI brain couldn't do something, in a sentence people can read.
public struct BrainError: Error, Hashable, Sendable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// How much a line of the brain's log matters (Windows' `Log.Info`, `Log.Warn` and `Log.Error`).
public enum BrainLogLevel: Hashable, Sendable {
    case info
    case warning
    case error
}
