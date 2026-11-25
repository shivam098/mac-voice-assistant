import Foundation
import ThumbFreeCore
import VoiceAssistantCore
import XCTest
@testable import VoiceAssistantMac

/// Settings' Download and Stop buttons (windows-voice-assistant AssistantHost.StartBrainDownload and
/// CancelBrainDownload): a download installs the brain and loads it, a damaged one fails and can be tried again, and a
/// stopped one carries on where it stopped.
final class BrainDownloadTests: XCTestCase {
    private var folder: BrainTempFolder!
    private var staging: BrainTempFolder!
    private var launcher: BrainFakeLauncher!
    private var logs: BrainRecorder<String>!
    private var brains: [LlamaBrain] = []
    private var archive = Data()
    private let model = Data((0..<2_097_152).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    override func setUpWithError() throws {
        folder = try BrainTempFolder()
        staging = try BrainTempFolder()
        launcher = BrainFakeLauncher()
        logs = BrainRecorder()
        archive = try BrainArchive.make(in: staging)
    }

    override func tearDown() {
        brains.forEach { $0.shutdown() }
        brains = []
        folder.remove()
        staging.remove()
    }

    /// A brain whose files this test serves, the model under `name` pinned to `pinned`'s hash.
    private func makeBrain(model name: String, pinned: Data) -> LlamaBrain {
        let id = UUID().uuidString
        let downloads = BrainFiles.Downloads(
            server: ModelFile(
                "llama-b12483-bin-macos-arm64.tar.gz", BrainFakeDownloads.serve("\(id)/llama.tar.gz", archive),
                brainSHA256(archive), Int64(archive.count)),
            model: ModelFile(
                "model.gguf", "https://brain.test/\(name)", brainSHA256(pinned), Int64(pinned.count)))
        let files = BrainFiles(
            folder: folder.path, serverPath: nil, modelPath: nil, downloads: downloads,
            session: BrainFakeDownloads.session())
        let brain = LlamaBrain(
            files: files, keepLoaded: 3600, http: BrainFakeLlama(), launcher: launcher, unavailableReason: nil,
            healthCheckInterval: 0.002, idleCheckInterval: 0)
        let logs = self.logs!
        brain.onLog = { _, line in logs.add(line) }
        brains.append(brain)
        return brain
    }

    func testADownloadInstallsTheBrainThenLoadsIt() async throws {
        let name = "\(UUID().uuidString)/model.gguf"
        _ = BrainFakeDownloads.serve(name, model)
        let brain = makeBrain(model: name, pinned: model)
        XCTAssertEqual(.notInstalled, brain.status)
        XCTAssertTrue(brain.canDownload)
        let seen = BrainRecorder<BrainStatus>()
        brain.onStatusChange = { seen.add($0) }

        let download = brain.startDownload()
        XCTAssertFalse(brain.canDownload)
        XCTAssertEqual(download, brain.startDownload(), "a second press joins the download")
        await download.value

        XCTAssertTrue(brain.files.isInstalled)
        let ready = await BrainWait.eventually { brain.status == .ready }
        XCTAssertTrue(ready, "loaded after the download: \(brain.status)")
        XCTAssertEqual(1, launcher.commands.count)
        XCTAssertFalse(brain.canDownload)
        XCTAssertEqual(["-"], BrainFakeDownloads.requests(name))
        XCTAssertTrue(logs.items.contains("brain: downloading 2 MB"), "\(logs.items)")
        XCTAssertTrue(logs.items.contains("brain: downloaded and verified"), "\(logs.items)")
        let settled = await BrainWait.eventually { seen.items.last == .ready }
        XCTAssertTrue(settled, "\(seen.items)")
        XCTAssertFalse(seen.items.contains { if case .failed = $0 { return true } else { return false } })
    }

    func testADamagedDownloadFailsAndTheNextOneStartsAfresh() async throws {
        let name = "\(UUID().uuidString)/model.gguf"
        _ = BrainFakeDownloads.serve(name, Data(model.reversed()))
        let brain = makeBrain(model: name, pinned: model)
        await brain.startDownload().value

        XCTAssertEqual(.failed("The download of model.gguf was damaged, so it was deleted. Try again."), brain.status)
        XCTAssertEqual(.notInstalled, brain.availability)
        XCTAssertTrue(brain.canDownload)
        XCTAssertTrue(logs.items.contains { $0.hasPrefix("brain: download failed: DownloadError") }, "\(logs.items)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.file("model.gguf.part")))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: brain.files.serverPath), "the server came through")

        _ = BrainFakeDownloads.serve(name, model)
        let download = brain.startDownload()
        guard case .downloading = brain.status else { return XCTFail("\(brain.status)") }
        await download.value
        let ready = await BrainWait.eventually { brain.status == .ready }
        XCTAssertTrue(ready, "\(brain.status)")
        XCTAssertEqual(["-", "-"], BrainFakeDownloads.requests(name))
    }

    func testStoppingADownloadKeepsWhatCameAndTheNextOneCarriesOn() async throws {
        let name = "\(UUID().uuidString)/model.gguf"
        _ = BrainFakeDownloads.serve(name, model, stall: true)
        let brain = makeBrain(model: name, pinned: model)
        let download = brain.startDownload()
        let part = folder.file("model.gguf.part")
        let half = await BrainWait.eventually {
            (try? FileManager.default.attributesOfItem(atPath: part)[.size] as? Int) == model.count / 2
        }

        XCTAssertTrue(half)
        guard case .downloading(_, let total) = brain.status else { return XCTFail("\(brain.status)") }
        XCTAssertEqual(Int64(archive.count + model.count), total)
        brain.cancelDownload()
        await download.value
        XCTAssertEqual(.notInstalled, brain.status)
        XCTAssertTrue(brain.canDownload)
        XCTAssertTrue(logs.items.contains("brain: download paused"), "\(logs.items)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: part))

        _ = BrainFakeDownloads.serve(name, model)
        await brain.startDownload().value
        let ready = await BrainWait.eventually { brain.status == .ready }
        XCTAssertTrue(ready, "\(brain.status)")
        XCTAssertEqual(["-", "bytes=\(model.count / 2)-"], BrainFakeDownloads.requests(name))
        XCTAssertEqual(model, try Data(contentsOf: URL(fileURLWithPath: brain.files.modelPath)))
    }
}
