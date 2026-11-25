import Foundation
import ThumbFreeCore
import XCTest
@testable import VoiceAssistantMac

/// Where the brain's files go and how they're downloaded (windows-voice-assistant src/VoiceAssistant.App/Brain/
/// BrainFiles.cs), with downloads served in the test: the paths and settings, what's missing, unpacking llama.cpp,
/// files chosen in settings, and which Macs can run it.
final class BrainFilesTests: XCTestCase {
    private var folder: BrainTempFolder!
    private var staging: BrainTempFolder!

    override func setUpWithError() throws {
        folder = try BrainTempFolder()
        staging = try BrainTempFolder()
    }

    override func tearDown() {
        folder.remove()
        staging.remove()
    }

    /// Files whose downloads this test serves: the server's archive and the model, each under a name of its own.
    private func served(
        server: Data, model: Data, serverPath: String? = nil, modelPath: String? = nil
    ) -> (files: BrainFiles, server: String, model: String) {
        let id = UUID().uuidString
        let downloads = BrainFiles.Downloads(
            server: ModelFile(
                "llama-b12483-bin-macos-arm64.tar.gz", BrainFakeDownloads.serve("\(id)/llama.tar.gz", server),
                brainSHA256(server), Int64(server.count)),
            model: ModelFile(
                "model.gguf", BrainFakeDownloads.serve("\(id)/model.gguf", model), brainSHA256(model),
                Int64(model.count)))
        let files = BrainFiles(
            folder: folder.path, serverPath: serverPath, modelPath: modelPath, downloads: downloads,
            session: BrainFakeDownloads.session())
        return (files, "\(id)/llama.tar.gz", "\(id)/model.gguf")
    }

    func testTheFilesGoInTheAppsFolderUnlessSettingsSayOtherwise() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
        let defaults = BrainFiles()
        XCTAssertEqual(support + "/VoiceAssistant/brain", defaults.folder)
        XCTAssertEqual(support + "/VoiceAssistant/brain/llama.cpp-b12483/llama-server", defaults.serverPath)
        XCTAssertEqual(support + "/VoiceAssistant/brain/Qwen3-4B-Instruct-2507-Q4_0.gguf", defaults.modelPath)

        let blank = BrainFiles(folder: "  ", serverPath: "", modelPath: "\t")
        XCTAssertEqual(defaults.folder, blank.folder)
        XCTAssertEqual(defaults.serverPath, blank.serverPath)
        XCTAssertEqual(defaults.modelPath, blank.modelPath)

        let inFolder = BrainFiles(folder: " /data/brain ")
        XCTAssertEqual("/data/brain", inFolder.folder)
        XCTAssertEqual("/data/brain/llama.cpp-b12483/llama-server", inFolder.serverPath)
        XCTAssertEqual("/data/brain/Qwen3-4B-Instruct-2507-Q4_0.gguf", inFolder.modelPath)

        let home = NSHomeDirectory()
        let chosen = BrainFiles(folder: "~/Brain", serverPath: "~/llama/llama-server", modelPath: " /models/qwen.gguf ")
        XCTAssertEqual(home + "/Brain", chosen.folder)
        XCTAssertEqual(home + "/llama/llama-server", chosen.serverPath)
        XCTAssertEqual("/models/qwen.gguf", chosen.modelPath)
    }

    func testWhatIsMissingIsWhatADownloadFetches() throws {
        let downloads = BrainFiles.Downloads(
            server: ModelFile("llama.tar.gz", "https://brain.test/a", "00", 1000),
            model: ModelFile("model.gguf", "https://brain.test/b", "00", 20))
        let files = BrainFiles(folder: folder.path, serverPath: nil, modelPath: nil, downloads: downloads)
        XCTAssertFalse(files.isInstalled)
        XCTAssertEqual(1020, files.missingBytes)

        try folder.write("model.gguf", "GGUF")
        XCTAssertEqual(1000, files.missingBytes)

        // A folder isn't a file.
        try FileManager.default.createDirectory(
            atPath: folder.file("llama.cpp-b12483/llama-server"), withIntermediateDirectories: true)
        XCTAssertFalse(files.isInstalled)
        try FileManager.default.removeItem(atPath: folder.file("llama.cpp-b12483/llama-server"))

        try folder.write("llama.cpp-b12483/llama-server", "#!/bin/sh\n", executable: true)
        XCTAssertEqual(0, files.missingBytes)
        XCTAssertTrue(files.isInstalled)

        // Files chosen in settings are never downloaded: when they're missing, there's nothing to download.
        let chosen = BrainFiles(
            folder: folder.path, serverPath: folder.file("mine/llama-server"),
            modelPath: folder.file("mine/model.gguf"), downloads: downloads)
        XCTAssertEqual(0, chosen.missingBytes)
        XCTAssertFalse(chosen.isInstalled)
    }

    func testADownloadUnpacksTheServerWithItsLinksAndDeletesTheArchive() async throws {
        let archive = try BrainArchive.make(in: staging)
        let model = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let (files, _, _) = served(server: archive, model: model)

        // Left by an earlier download: an unpacking that stopped, and a server folder without its server.
        try folder.write("llama.cpp-b12483.unpacking/half", "?")
        try folder.write("llama.cpp-b12483/leftover", "old")

        let seen = BrainRecorder<(Int64, Int64)>()
        try await files.download { seen.add(($0, $1)) }

        XCTAssertTrue(files.isInstalled)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: files.serverPath))
        XCTAssertEqual(
            "libllama.1.0.0.dylib",
            try FileManager.default.destinationOfSymbolicLink(atPath: folder.file("llama.cpp-b12483/libllama.1.dylib")))
        XCTAssertEqual(model, try Data(contentsOf: URL(fileURLWithPath: files.modelPath)))
        XCTAssertEqual(
            ["libllama.1.0.0.dylib", "libllama.1.dylib", "llama-server"],
            try FileManager.default.contentsOfDirectory(atPath: folder.file("llama.cpp-b12483")).sorted())

        // The archive is gone; the model store keeps its list of checked files.
        XCTAssertEqual(
            ["llama.cpp-b12483", "model.gguf", "verified.tsv"],
            try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted())

        let total = Int64(archive.count + model.count)
        let progress = seen.items
        XCTAssertEqual(total, progress.last?.0)
        XCTAssertTrue(progress.allSatisfy { $0.1 == total })
        XCTAssertEqual(progress.map { $0.0 }, progress.map { $0.0 }.sorted(), "progress went back")
    }

    func testFilesChosenInSettingsAreNeverDownloadedOverOrDeleted() async throws {
        let mine = try folder.write("mine/llama-server", "#!/bin/sh\n# mine\n", executable: true)
        let written = try FileManager.default.attributesOfItem(atPath: mine)[.modificationDate] as? Date
        let model = Data(repeating: 7, count: 1000)
        let (files, server, _) = served(server: Data("unused".utf8), model: model, serverPath: mine)
        XCTAssertEqual(1000, files.missingBytes)

        try await files.download { _, _ in }
        XCTAssertTrue(files.isInstalled)
        XCTAssertEqual([], BrainFakeDownloads.requests(server))
        XCTAssertEqual("#!/bin/sh\n# mine\n", try String(contentsOfFile: mine, encoding: .utf8))
        XCTAssertEqual(written, try FileManager.default.attributesOfItem(atPath: mine)[.modificationDate] as? Date)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.file("llama.cpp-b12483")))
    }

    func testAChosenFileThatIsMissingStopsTheDownload() async throws {
        let (files, server, model) = served(
            server: Data("unused".utf8), model: Data("unused".utf8), modelPath: folder.file("nowhere.gguf"))
        do {
            try await files.download { _, _ in }
            XCTFail("downloaded")
        } catch {
            XCTAssertEqual(
                BrainError("A file chosen in settings.json (brainServerPath or brainModelPath) doesn't exist."),
                error as? BrainError)
        }

        XCTAssertEqual([], BrainFakeDownloads.requests(server) + BrainFakeDownloads.requests(model))
    }

    func testAnArchiveWithoutTheServerIsNotInstalled() async throws {
        let (files, _, model) = served(server: Data("not an archive".utf8), model: Data("GGUF".utf8))
        do {
            try await files.download { _, _ in }
            XCTFail("downloaded")
        } catch {
            XCTAssertEqual(BrainError("The llama.cpp download couldn't be unpacked. Try again."), error as? BrainError)
        }

        XCTAssertFalse(files.isInstalled)
        XCTAssertEqual([], BrainFakeDownloads.requests(model), "the model waits for a working server")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.file("llama.cpp-b12483")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.file("llama.cpp-b12483.unpacking")))
    }

    func testAppleSiliconMacsRunTheBrainAndTheDownloadedServerNeedsMacOS13_3() {
        let sequoia = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        let ventura3 = OperatingSystemVersion(majorVersion: 13, minorVersion: 3, patchVersion: 0)
        let ventura2 = OperatingSystemVersion(majorVersion: 13, minorVersion: 2, patchVersion: 1)
        let intel = "The AI brain needs a Mac with Apple silicon. It isn't available on Intel Macs yet."
        XCTAssertNil(BrainFiles.reasonUnavailable(appleSilicon: true, macOS: sequoia, serverChosen: false))
        XCTAssertNil(BrainFiles.reasonUnavailable(appleSilicon: true, macOS: ventura3, serverChosen: false))
        XCTAssertEqual(
            "The AI brain needs macOS 13.3 or later.",
            BrainFiles.reasonUnavailable(appleSilicon: true, macOS: ventura2, serverChosen: false))
        XCTAssertNil(BrainFiles.reasonUnavailable(appleSilicon: true, macOS: ventura2, serverChosen: true))
        XCTAssertEqual(intel, BrainFiles.reasonUnavailable(appleSilicon: false, macOS: sequoia, serverChosen: false))
        XCTAssertEqual(intel, BrainFiles.reasonUnavailable(appleSilicon: false, macOS: sequoia, serverChosen: true))

        #if arch(arm64)
        // GitHub's runners: Apple silicon, macOS 15.
        XCTAssertTrue(BrainFiles.isAppleSilicon)
        XCTAssertNil(BrainFiles().unavailableReason)
        #endif
    }
}
