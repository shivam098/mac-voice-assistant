import CryptoKit
import Darwin
import Foundation
import VoiceAssistantCore
import XCTest
@testable import VoiceAssistantMac

/// windows-voice-assistant's brain bench on the Mac (tools/BrainSpike; the cases are in BrainBench.swift). The first
/// two tests hold the port to the C#: the same user messages, and the same verdicts on the same replies. The third is
/// the bench itself, with the real model on this Mac. It runs only when BRAIN_BENCH_FOLDER names a folder for the
/// brain's files (.github/workflows/brain-bench.yml), never in ordinary CI.
final class BrainBenchTests: XCTestCase {
    private static let rows: [[String]] = brainBenchVectors.split(separator: "\n").map {
        $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    }

    func testTheCasesAskWhatWindowsAsks() {
        let rows = Self.rows.filter { $0.first == "case" }
        XCTAssertEqual(BrainBench.cases.count, rows.count)
        for row in rows {
            guard row.count == 5, let number = Int(row[1]), BrainBench.cases.indices.contains(number) else {
                XCTFail("bad row: \(row)")
                continue
            }

            let benchCase = BrainBench.cases[number]
            let message = BrainPrompt.userMessage(benchCase.screen, benchCase.request)
            let hash = SHA256.hash(data: Data(message.utf8)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(row[2], benchCase.request)
            XCTAssertEqual(row[3], hash, benchCase.request)
            XCTAssertEqual(Int(row[4]), message.utf16.count, benchCase.request)
        }
    }

    func testTheChecksJudgeRepliesAsWindowsDoes() {
        let rows = Self.rows.filter { $0.first == "reply" }
        XCTAssertGreaterThan(rows.count, BrainBench.cases.count)
        for row in rows {
            guard row.count >= 5, let number = Int(row[1]), BrainBench.cases.indices.contains(number) else {
                XCTFail("bad row: \(row)")
                continue
            }

            let reply = row[4...].joined(separator: "\t")
            let verdict = BrainBench.judge(reply, BrainBench.cases[number])
            XCTAssertEqual(row[2] == "1", verdict.passed, "case \(number): \(reply)")
            XCTAssertEqual(row[3] == "1", verdict.clean, "case \(number): \(reply)")
        }

        // Windows' own plans, one for each case: its 22/25, missing the same three. And its median, taken as Bench.cs
        // takes it.
        let windows = rows.prefix(BrainBench.cases.count)
        XCTAssertEqual(Array(0..<BrainBench.cases.count), windows.compactMap { Int($0[1]) })
        let missed = windows.filter { $0[2] == "0" }.compactMap { Int($0[1]) }.map { BrainBench.cases[$0].request }
        XCTAssertEqual(BrainBench.windowsMisses, Set(missed))
        let times = BrainBench.windowsMilliseconds.map {
            BrainBench.Outcome(request: "", passed: true, clean: true, milliseconds: $0, plan: "")
        }

        XCTAssertEqual(BrainBench.cases.count, times.count)
        XCTAssertEqual(1908, BrainBench.medianAndSlowest(times).median)
    }

    /// The bench: llama.cpp for this Mac's processor and the Qwen3 4B model (downloaded where missing), started as the
    /// app starts it, then the 25 requests in order, timed. It prints Bench.cs's lines and writes a Markdown summary to
    /// BRAIN_BENCH_SUMMARY.
    func testBenchOnThisMac() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["BRAIN_BENCH_FOLDER"], !folder.isEmpty else {
            throw XCTSkip("Set BRAIN_BENCH_FOLDER to a folder for llama.cpp and the model (2.4 GB) to run the bench.")
        }

        let label = environment["BRAIN_BENCH_LABEL"] ?? "This Mac"
        let machine = BrainBenchMachine.describe()
        let files = BrainFiles(folder: folder)
        Self.say("== Brain bench: \(label). \(machine)")

        // The files. CI keeps the model between runs.
        var downloaded = "both were there already"
        if !files.isInstalled {
            let modelKept = BrainFiles.isFile(files.modelPath)
            let missing = files.missingBytes
            let downloadStarted = Date()
            let tenths = BrainRecorder<Int64>()
            try await files.download { received, total in
                let tenth = total > 0 ? received * 10 / total : 0
                if tenth > (tenths.items.last ?? -1) {
                    tenths.add(tenth)
                    BrainBenchTests.say("downloading: \(tenth * 10)% of \(total / 1_000_000) MB")
                }
            }

            let seconds = Int(Date().timeIntervalSince(downloadStarted).rounded())
            downloaded = (modelKept ? "llama.cpp downloaded, the model kept from an earlier run" : "both downloaded")
                + " (\(missing / 1_000_000) MB in \(seconds) s)"
        }

        XCTAssertTrue(files.isInstalled)

        // The server, started as the app starts it, with its memory sampled from its start. Intel Macs aren't offered
        // the brain yet (`unavailableReason`); the bench measures them all the same.
        let log = environment["BRAIN_BENCH_SERVER_LOG"]
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("brain-bench-llama-server.log")
        // The supervisor appends to it: this run's log only.
        try? FileManager.default.removeItem(atPath: log)
        let brain = LlamaBrain(
            files: files, keepLoaded: 0, http: URLSessionBrainHTTP(), launcher: ServerSupervisor(output: log),
            unavailableReason: nil, idleCheckInterval: 0)
        let timings = BrainRecorder<String>()
        brain.onLog = { _, line in
            BrainBenchTests.say(line)
            if line.hasPrefix("brain: prompt ") {
                timings.add(line)
            }
        }

        defer { brain.shutdown() }
        let started = Date()
        let loading = Task { try await brain.ensureReady() }
        var memory: BrainBenchMemory?
        for _ in 0..<1000 where memory == nil {
            if let server = brain.serverProcess {
                memory = BrainBenchMemory(process: server.serverID)
            } else {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        defer { memory?.stop() }
        try await loading.value
        let loaded = Date().timeIntervalSince(started)
        let server = try XCTUnwrap(brain.serverProcess)
        Self.say("== loaded in \(Int((loaded * 1000).rounded())) ms (llama-server, pid \(server.serverID))")

        let outcomes = await BrainBench.run(output: Self.say) { messages in try await brain.complete(messages) }
        memory?.stop()
        let report = BrainBenchReport(
            label: label, machine: machine, files: files, downloaded: downloaded, loaded: loaded, outcomes: outcomes,
            timings: timings.items, peakResident: memory?.peakResident ?? 0,
            peakFootprint: BrainBenchMemory.peakFootprint(server.serverID) ?? 0,
            serverLog: (try? String(contentsOfFile: log, encoding: .utf8)) ?? "")
        Self.say("  clean (correct and no extra steps): \(report.clean)/\(outcomes.count)")
        Self.say(report.line)
        if let path = environment["BRAIN_BENCH_SUMMARY"] {
            try report.markdown.write(toFile: path, atomically: true, encoding: .utf8)
        }

        XCTAssertEqual(BrainBench.cases.count, outcomes.count)
    }

    private static func say(_ line: String) {
        print(line)
        // In order with XCTest's own lines.
        fflush(stdout)
    }
}

/// What the bench found, as a line for the log and Markdown for the job's summary. Memory is in GB of 1024³ bytes, as
/// macOS shows it.
struct BrainBenchReport {
    var label: String
    var machine: String
    var files: BrainFiles
    var downloaded: String
    var loaded: TimeInterval
    var outcomes: [BrainBench.Outcome]
    var timings: [String]
    var peakResident: UInt64
    var peakFootprint: UInt64
    var serverLog: String

    var passed: Int { outcomes.filter(\.passed).count }

    var clean: Int { outcomes.filter(\.clean).count }

    /// Of the 21 requests that ai-brain.md's "18/21" counts.
    var passedOfFirst21: Int { outcomes.prefix(21).filter(\.passed).count }

    var line: String {
        let (median, slowest) = BrainBench.medianAndSlowest(outcomes)
        return [
            "== \(label): \(passed)/\(outcomes.count) passed (\(passedOfFirst21)/21 of the first 21), ",
            "median \(Int(median.rounded())) ms, slowest \(Int(slowest.rounded())) ms, ",
            "loaded in \(Int((loaded * 1000).rounded())) ms, peak memory \(memory)",
        ].joined()
    }

    var memory: String { "\(Self.gigabytes(peakResident)) resident, \(Self.gigabytes(peakFootprint)) footprint" }

    /// The graphics chip llama-server found, and whether it has what llama.cpp's Metal code needs for the model's
    /// matrix multiplications (simdgroup reduction), from its log (CI raises its log level for this).
    var graphics: String {
        guard let name = logged(after: "GPU name:") else { return "none: the processor only" }
        return logged(after: "simdgroup reduction").map { "\(name), simdgroup reduction \($0)" } ?? name
    }

    /// Where llama-server put the model's weights, its KV cache and its working memory, from its log: MiB in each kind
    /// of buffer (CPU_REPACK is weights rearranged for the processor; MTL0 is the graphics chip).
    var buffers: String {
        let kinds = [
            ("weights", " model buffer size = "), ("KV cache", " KV buffer size = "),
            ("work", " compute buffer size = "),
        ]
        let lines = serverLog.components(separatedBy: "\n")
        var parts: [String] = []
        for (label, marker) in kinds {
            var sizes: [(kind: String, mib: Double)] = []
            for line in lines {
                guard let found = line.range(of: marker) else { continue }
                let kind = line[..<found.lowerBound].split(separator: " ").last.map(String.init) ?? "?"
                let mib = Double(line[found.upperBound...].split(separator: " ").first ?? "") ?? 0
                if let index = sizes.firstIndex(where: { $0.kind == kind }) {
                    sizes[index].mib += mib
                } else {
                    sizes.append((kind: kind, mib: mib))
                }
            }

            if !sizes.isEmpty {
                let listed = sizes.map { "\($0.kind) \(Int($0.mib.rounded())) MiB" }
                parts.append("\(label) " + listed.joined(separator: ", "))
            }
        }

        return parts.joined(separator: "; ")
    }

    /// Reading and writing speeds over every request, from llama-server's timings.
    var speeds: String {
        var promptTokens = 0.0
        var promptMs = 0.0
        var replyTokens = 0.0
        var replyMs = 0.0
        for line in timings {
            // "brain: prompt 117 tokens (689 cached) in 694 ms, reply 46 tokens in 2283 ms": 117 tokens read.
            let numbers = line.split(whereSeparator: { !$0.isNumber && $0 != "." }).compactMap { Double($0) }
            guard numbers.count == 5 else { continue }
            promptTokens += numbers[0]
            promptMs += numbers[2]
            replyTokens += numbers[3]
            replyMs += numbers[4]
        }

        guard promptMs > 0, replyMs > 0 else { return "not reported" }
        return "\(Int((promptTokens / promptMs * 1000).rounded())) tokens/s reading prompts, "
            + "\(Int((replyTokens / replyMs * 1000).rounded())) tokens/s writing replies"
    }

    var markdown: String {
        let (median, slowest) = BrainBench.medianAndSlowest(outcomes)
        var text = """
            ## Brain bench: \(label)

            windows-voice-assistant's 25 brain requests (tools/BrainSpike) through the app's prompt and plan reader \
            and LlamaBrain's llama-server, started as the app starts it: llama.cpp \(BrainFiles.llamaBuild) \
            (`\(files.downloads.server.path)`) and `\(files.downloads.model.path)`, temperature 0, the plan grammar.

            - **This Mac:** \(machine)
            - **Graphics:** \(graphics)
            - **Where llama.cpp put the model:** \(buffers.isEmpty ? "not in its log" : buffers)
            - **Files:** \(downloaded)

            | | This Mac | Windows (v0.12.1: Snapdragon X Elite, its Adreno GPU) |
            |---|---|---|
            | Correct, the first 21 requests | **\(passedOfFirst21)/21** | 18/21 |
            | Correct, all 25 | **\(passed)/\(outcomes.count)** | 22/25 |
            | Clean (correct, in 3 steps or fewer) | \(clean)/\(outcomes.count) | 22/25 |
            | Median time per request | **\(Self.seconds(median))** | 1.9 s |
            | Slowest request | \(Self.seconds(slowest)) | 7.0 s (the first, with an empty prompt cache) |
            | First load (start to ready) | \(Self.seconds(loaded * 1000)) | 7–14 s |
            | llama-server's peak memory | \(memory) | not measured |
            | Speed | \(speeds) | about 250 tokens/s reading, 16–19 tokens/s writing |

            | # | Request | This Mac | Time | Windows | Windows' time | Plan |
            |---|---|---|---|---|---|---|

            """
        for (number, outcome) in outcomes.enumerated() {
            let windows = BrainBench.windowsMisses.contains(outcome.request) ? "FAIL" : "PASS"
            let windowsTime = number < BrainBench.windowsMilliseconds.count
                ? Self.seconds(BrainBench.windowsMilliseconds[number]) : ""
            let plan = outcome.plan.replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            text += "| \(number + 1) | \(outcome.request) | \(outcome.passed ? "PASS" : "**FAIL**") | "
                + "\(Self.seconds(outcome.milliseconds)) | \(windows) | \(windowsTime) | \(plan) |\n"
        }

        return text
    }

    static func seconds(_ milliseconds: Double) -> String { String(format: "%.1f s", milliseconds / 1000) }

    static func gigabytes(_ bytes: UInt64) -> String { String(format: "%.2f GB", Double(bytes) / 1_073_741_824) }

    /// What follows `marker` on the first line of llama-server's log that has it.
    private func logged(after marker: String) -> String? {
        for line in serverLog.components(separatedBy: "\n") {
            if let found = line.range(of: marker) {
                return line[found.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return nil
    }
}

/// The Mac the bench runs on, from sysctl.
enum BrainBenchMachine {
    static func describe() -> String {
        let processor = text("machdep.cpu.brand_string") ?? "unknown processor"
        let cores = number("hw.ncpu").map { "\($0) cores" } ?? "? cores"
        let memory = number("hw.memsize").map { String(format: "%.1f GB", Double($0) / 1_073_741_824) } ?? "? GB"
        return "\(processor), \(cores), \(memory), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    private static func text(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func number(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        // hw.ncpu is 4 bytes, hw.memsize 8: on a little-endian Mac the low bytes come first either way.
        return value
    }
}
