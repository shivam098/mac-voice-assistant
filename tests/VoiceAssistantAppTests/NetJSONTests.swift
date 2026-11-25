import XCTest
@testable import VoiceAssistantApp

/// What the files' JSON writer writes, against what System.Text.Json wrote for the same values (AppVectors.swift).
final class NetJSONTests: XCTestCase {
    func testFloatsAreWrittenAsDotNetWritesThem() throws {
        let lines = Escaped.lines(floatVectors)
        for line in lines {
            let fields = Escaped.fields(line)
            let value = Float(bitPattern: try XCTUnwrap(UInt32(fields[1], radix: 16)))
            XCTAssertEqual(try NetJSON.number(value), fields[2], "\(value)")
        }

        XCTAssertEqual(lines.count, 26)
        XCTAssertThrowsError(try NetJSON.number(.infinity))
        XCTAssertThrowsError(try NetJSON.number(.nan))
    }

    func testTextIsEscapedAsDotNetEscapesIt() throws {
        let lines = Escaped.lines(escapeVectors)
        for line in lines {
            let fields = Escaped.fields(line)
            XCTAssertEqual(NetJSON.quote(fields[1]), fields[2], fields[1])
            let key = NetJSON.Value.object([NetJSON.Property(fields[1], .int(1))])
            XCTAssertEqual(try NetJSON.write(key, indented: false), fields[3], fields[1])
        }

        XCTAssertEqual(lines.count, 20)
    }

    func testIndentedJSONIsLaidOutAsDotNetLaysItOut() throws {
        let value = NetJSON.Value.object([
            NetJSON.Property("a", .array([.int(1), .bool(true), .array([]), .object([])])),
            NetJSON.Property("b", .object([NetJSON.Property("c", .string("d"))])),
            NetJSON.Property("e", .float(0.25)),
        ])

        XCTAssertEqual(
            try NetJSON.write(value, indented: true),
            "{\n  \"a\": [\n    1,\n    true,\n    [],\n    {}\n  ],\n"
                + "  \"b\": {\n    \"c\": \"d\"\n  },\n  \"e\": 0.25\n}")
        XCTAssertEqual(try NetJSON.write(value, indented: false), #"{"a":[1,true,[],{}],"b":{"c":"d"},"e":0.25}"#)
    }

    /// Numbers past a float's range read as .NET reads them, whatever the C library says about them.
    func testNumbersReadAsDotNetReadsThem() {
        XCTAssertEqual(NetJSON.Reader.float("0.3"), 0.3)
        XCTAssertEqual(NetJSON.Reader.float("1e39"), .infinity)
        XCTAssertEqual(NetJSON.Reader.float("-1e400"), -.infinity)
        XCTAssertEqual(NetJSON.Reader.float("1e-50"), 0)
        XCTAssertEqual(NetJSON.Reader.float("-0.000001e-400"), 0)
        XCTAssertEqual(NetJSON.Reader.float("1e-45"), Float(bitPattern: 1))
        XCTAssertEqual(NetJSON.Reader.int("-0"), 0)
        XCTAssertNil(NetJSON.Reader.int("1.0"))
        XCTAssertNil(NetJSON.Reader.int("2147483648"))
    }
}
