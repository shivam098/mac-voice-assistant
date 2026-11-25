import CryptoKit
import XCTest
import ThumbFreeCore
import ThumbFreeSpeech
@testable import VoiceAssistantApp

/// The models Windows' ModelDownloader downloads, downloaded through ThumbFreeSpeech's ModelStore from a server that
/// only these tests' sessions reach (`FakeServer`).
final class ModelDownloaderTests: XCTestCase {
    /// Windows' `ModelDownloader.Known`: file, address and SHA-256 (the sizes are the files').
    func testTheModelsAreWindowsFilesAddressesAndHashes() {
        let whisperCpp = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"
        let whisperVad = "https://huggingface.co/ggml-org/whisper-vad/resolve/main/"
        let releases = "https://github.com/shivam098/windows-voice-assistant/releases/download/"
        let windows: [(String, String, String)] = [
            ("ggml-small.en-q8_0.bin", whisperCpp + "ggml-small.en-q8_0.bin",
             "67a179f608ea6114bd3fdb9060e762b588a3fb3bd00c4387971be4d177958067"),
            ("ggml-base.en-q8_0.bin", whisperCpp + "ggml-base.en-q8_0.bin",
             "a4d4a0768075e13cfd7e19df3ae2dbc4a68d37d36a7dad45e8410c9a34f8c87e"),
            ("ggml-base.en.bin", whisperCpp + "ggml-base.en.bin",
             "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"),
            ("ggml-silero-v6.2.0.bin", whisperVad + "ggml-silero-v6.2.0.bin",
             "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"),
            ("ggml-hinglish-swift-q8_0.bin", releases + "models-hinglish-swift-1/ggml-hinglish-swift-q8_0.bin",
             "0cf6e7077971d9aa43963b04bf764a47600e873f7e0f3f0f9742323560171245"),
            ("ggml-hinglish-apex-q8_0.bin", releases + "models-hinglish-apex-1/ggml-hinglish-apex-q8_0.bin",
             "0b4324d2c1ad64f20883ee7fcd5d2bb0a8466287dc70d74bc47066200c28c719"),
        ]

        let catalog = ModelDownloader.catalog
        XCTAssertEqual(catalog.map(\.path), windows.map { $0.0 })
        XCTAssertEqual(catalog.map(\.url), windows.map { $0.1 })
        XCTAssertEqual(catalog.map(\.sha256), windows.map { $0.2 })
        XCTAssertEqual(catalog.map(\.bytes), [264_477_561, 81_781_811, 147_964_211, 885_098, 81_768_585, 874_188_075])
        XCTAssertEqual(catalog[3], ModelCatalog.vad)
        XCTAssertEqual(catalog[4], ModelCatalog.hinglish.files[0])
        XCTAssertEqual(catalog[5], ModelCatalog.hinglishAccurate.files[0])
        XCTAssertEqual(AppSettings().modelFile, catalog[0].name)
        XCTAssertEqual(AppSettings().vadModelFile, catalog[3].name)

        XCTAssertTrue(ModelDownloader.canDownload("ggml-small.en-q8_0.bin"))
        XCTAssertTrue(ModelDownloader.canDownload("GGML-Small.EN-q8_0.BIN"))
        XCTAssertFalse(ModelDownloader.canDownload("ggml-large.bin"))
        XCTAssertFalse(ModelDownloader.canDownload(""))
    }

    func testAModelIsDownloadedIntoVoiceAssistantsFolderReportingEachPercentOnce() async throws {
        let folder = TempFolder()
        defer { folder.remove() }
        let bytes = Self.bytes(3 * 1024 * 1024)
        let file = FakeServer.add("ggml-test.bin", bytes)
        let downloader = Self.downloader(folder, catalog: [file])
        let reported = Locked<[Int]>([])

        XCTAssertNil(downloader.path(of: "ggml-test.bin"))
        try await downloader.download("GGML-TEST.bin") { percent in reported.update { $0.append(percent) } }

        let path = folder.file("models/ggml-test.bin")
        XCTAssertEqual(downloader.path(of: "ggml-test.bin"), path)
        XCTAssertTrue(downloader.isInstalled("ggml-test.bin"))
        XCTAssertEqual(TestFiles.bytes(path), bytes)
        XCTAssertEqual(reported.value.last, 100)
        XCTAssertGreaterThan(reported.value.count, 2)
        XCTAssertEqual(reported.value, reported.value.sorted())
        XCTAssertEqual(Set(reported.value).count, reported.value.count)
        XCTAssertEqual(FakeServer.requests(for: "ggml-test.bin"), 1)

        // Already here and intact: nothing more is downloaded.
        try await downloader.download("ggml-test.bin") { _ in }
        XCTAssertEqual(FakeServer.requests(for: "ggml-test.bin"), 1)
    }

    /// A model ThumbFree for Mac already downloaded is used from its folder, read only, rather than downloaded again.
    func testAModelInThumbFreesFolderIsUsedFromThere() async throws {
        let folder = TempFolder()
        defer { folder.remove() }
        let bytes = Self.bytes(100_000)
        let file = FakeServer.add("ggml-shared.bin", bytes)
        let shared = folder.file("thumbfree/ggml-shared.bin")
        TestFiles.write(shared, bytes: bytes)
        let downloader = Self.downloader(folder, catalog: [file])

        XCTAssertEqual(downloader.path(of: "ggml-shared.bin"), shared)
        try await downloader.download("ggml-shared.bin") { _ in }

        XCTAssertEqual(FakeServer.requests(for: "ggml-shared.bin"), 0)
        XCTAssertFalse(TestFiles.exists(folder.file("models/ggml-shared.bin")))
        XCTAssertEqual(TestFiles.bytes(shared), bytes)
    }

    func testADamagedDownloadIsDeletedAndSaysSo() async throws {
        let folder = TempFolder()
        defer { folder.remove() }
        let bytes = Self.bytes(50_000)
        let served = FakeServer.add("ggml-damaged.bin", bytes)
        let file = ModelFile(served.path, served.url, String(repeating: "0", count: 64), served.bytes)
        let downloader = Self.downloader(folder, catalog: [file])

        do {
            try await downloader.download("ggml-damaged.bin") { _ in }
            XCTFail("A damaged download was kept")
        } catch let error as DownloadError {
            XCTAssertEqual(error.message, "The download of ggml-damaged.bin was damaged, so it was deleted. Try again.")
        }

        XCTAssertNil(downloader.path(of: "ggml-damaged.bin"))
        XCTAssertFalse(TestFiles.exists(folder.file("models/ggml-damaged.bin")))
        XCTAssertFalse(TestFiles.exists(folder.file("models/ggml-damaged.bin.part")))
    }

    func testAModelItDoesntKnowIsntDownloaded() async throws {
        let folder = TempFolder()
        defer { folder.remove() }
        let downloader = ModelDownloader(paths: AppPaths(data: folder.path, logs: folder.file("logs")))

        XCTAssertNil(downloader.path(of: "ggml-small.en-q8_0.bin"))
        XCTAssertNil(downloader.file(named: "ggml-large.bin"))
        do {
            try await downloader.download("ggml-large.bin") { _ in }
            XCTFail("An unknown model was downloaded")
        } catch let error as DownloadError {
            XCTAssertEqual(error.message, "Voice Assistant can't download ggml-large.bin: it isn't one of its models.")
        }
    }

    /// A store in the test folder's models/, sharing its thumbfree/, reached through the fake server.
    private static func downloader(_ folder: TempFolder, catalog: [ModelFile]) -> ModelDownloader {
        let paths = AppPaths(data: folder.path, logs: folder.file("logs"), sharedModels: [folder.file("thumbfree")])
        let store = ModelStore(
            primaryFolder: paths.models, sharedFolders: paths.sharedModels, session: FakeServer.session,
            retryDelay: 0.01)
        return ModelDownloader(store: store, catalog: catalog)
    }

    /// Bytes that differ from one test run to the next.
    private static func bytes(_ count: Int) -> [UInt8] { (0..<count).map { _ in UInt8.random(in: 0...255) } }
}

/// Serves files over HTTP to the sessions that use it, without a network (URLProtocol): the whole file, or the rest of
/// it for a Range request, in 256 KB pieces, so progress is reported along the way.
final class FakeServer: URLProtocol {
    static let host = "models.test"

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeServer.self]
        return URLSession(configuration: configuration)
    }()

    private static let state = Locked<(files: [String: [UInt8]], requests: [String: Int])>((files: [:], requests: [:]))

    /// Serves `bytes` as `name`; returns the model file to download it with.
    static func add(_ name: String, _ bytes: [UInt8]) -> ModelFile {
        state.update { $0.files[name] = bytes }
        let sha256 = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
        return ModelFile(name, "https://\(host)/\(name)", sha256, Int64(bytes.count))
    }

    static func requests(for name: String) -> Int { state.value.requests[name] ?? 0 }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let name = String(url.path.dropFirst())
        var bytes: [UInt8]?
        Self.state.update { state in
            state.requests[name, default: 0] += 1
            bytes = state.files[name]
        }

        guard let bytes else {
            respond(404, [:], [])
            return
        }

        let range = request.value(forHTTPHeaderField: "Range")
        if let range, range.hasPrefix("bytes="), range.hasSuffix("-"), let from = Int(range.dropFirst(6).dropLast()),
           from < bytes.count {
            respond(206, ["Content-Range": "bytes \(from)-\(bytes.count - 1)/\(bytes.count)"], Array(bytes[from...]))
        } else {
            respond(200, [:], bytes)
        }
    }

    override func stopLoading() {}

    private func respond(_ status: Int, _ headers: [String: String], _ body: [UInt8]) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: headers.merging(["Content-Length": "\(body.count)"]) { first, _ in first })
        else { return }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var at = 0
        while at < body.count {
            let end = min(at + 256 * 1024, body.count)
            client?.urlProtocol(self, didLoad: Data(body[at..<end]))
            at = end
        }

        client?.urlProtocolDidFinishLoading(self)
    }
}
