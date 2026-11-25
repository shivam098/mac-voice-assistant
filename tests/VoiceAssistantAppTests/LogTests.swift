import XCTest
@testable import VoiceAssistantApp

/// The log has no tests on Windows; these cover where the Mac writes it, what a line holds, how long logs are kept and
/// how big one grows, and that an error is logged by its kind.
final class LogTests: XCTestCase {
    func testLinesGoToTheDaysFileAndLogsOlderThanAWeekGo() throws {
        let folder = TempFolder()
        defer {
            Log.stop()
            folder.remove()
        }

        let now = Date()
        let old = folder.file("20000101.log")
        let recent = folder.file("20000102.log")
        let other = folder.file("notes.txt")
        for (path, days) in [(old, 8.0), (recent, 6.0), (other, 30.0)] {
            TestFiles.write(path, "x\n")
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-days * 24 * 60 * 60)], ofItemAtPath: path)
        }

        Log.start(in: folder.path, now: now)
        Log.info("listening; model small.en loaded in 812 ms")
        Log.warn("learned memory not saved: NSCocoaErrorDomain 640")
        Log.error("typing failed")

        XCTAssertFalse(TestFiles.exists(old))
        XCTAssertTrue(TestFiles.exists(recent))
        XCTAssertTrue(TestFiles.exists(other))
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyyMMdd"
        let file = try XCTUnwrap(Log.file)
        XCTAssertEqual(file, folder.file(day.string(from: now) + ".log"))
        let lines = TestFiles.text(file).split(separator: "\n").map(String.init)
        let expected = [
            "INFO listening; model small.en loaded in 812 ms", "WARN learned memory not saved: NSCocoaErrorDomain 640",
            "ERROR typing failed",
        ]
        XCTAssertEqual(lines.count, expected.count)
        for (line, message) in zip(lines, expected) {
            XCTAssertNotNil(line.range(of: #"^\d\d:\d\d:\d\d\.\d\d\d "#, options: .regularExpression), line)
            XCTAssertTrue(line.hasSuffix(" " + message), line)
        }
    }

    func testAFileStopsGrowingPastFiveMegabytes() throws {
        let folder = TempFolder()
        defer {
            Log.stop()
            folder.remove()
        }

        Log.start(in: folder.path)
        let file = try XCTUnwrap(Log.file)
        TestFiles.write(file, bytes: [UInt8](repeating: 0x2E, count: Log.maxBytes))
        Log.info("still fits")
        let size = TestFiles.bytes(file).count
        XCTAssertGreaterThan(size, Log.maxBytes)

        Log.info("dropped")
        XCTAssertEqual(TestFiles.bytes(file).count, size)
    }

    func testNothingIsLoggedBeforeItStartsOrWhenItsFolderCantBeMade() throws {
        let folder = TempFolder()
        defer {
            Log.stop()
            folder.remove()
        }

        Log.stop()
        Log.info("nowhere")
        TestFiles.write(folder.file("file"), "x")
        Log.start(in: folder.file("file/logs"))
        XCTAssertNil(Log.file)
        Log.info("nowhere either")
    }

    func testAnErrorIsLoggedByItsKindNeverItsMessage() {
        let path = "/Users/ren/Documents/secret.txt"
        let error = NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [NSFilePathErrorKey: path])

        XCTAssertEqual(Log.kind(of: error), "NSCocoaErrorDomain 513")
        XCTAssertFalse(Log.kind(of: AppSettings.ReadError("Thanks, Ren")).contains("Ren"))
    }
}
