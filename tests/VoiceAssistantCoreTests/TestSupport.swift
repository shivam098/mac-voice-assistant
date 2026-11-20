import Foundation
import XCTest
@testable import VoiceAssistantCore

/// A rectangle, as the C# tests' `R(x, y, w, h)`.
func rect(_ x: Double, _ y: Double, _ width: Double = 100, _ height: Double = 30) -> ScreenRect {
    ScreenRect(x: x, y: y, width: width, height: height)
}

/// Checks each case, naming it in the failure.
func check<Input, Output: Equatable>(
    _ cases: [(Input, Output)],
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: (Input) -> Output
) {
    for (input, expected) in cases {
        XCTAssertEqual(body(input), expected, "\(input)", file: file, line: line)
    }
}

/// .NET's `new Random(seed)`: the seeded generator (Knuth's subtractive method) that `Random` keeps for compatibility,
/// so a seed gives the numbers it gives in C#. (The same as thumbfree-mac's test copy, with `nextDouble`.)
struct DotNetRandom {
    private var seeds = [Int](repeating: 0, count: 56)
    private var inext = 0
    private var inextp = 21

    init(_ seed: Int) {
        let intMax = Int(Int32.max)
        var mj = 161_803_398 - (seed == Int(Int32.min) ? intMax : abs(seed))
        seeds[55] = mj
        var mk = 1
        var ii = 0
        for _ in 1..<55 {
            ii += 21
            if ii >= 55 {
                ii -= 55
            }

            seeds[ii] = mk
            mk = mj - mk
            if mk < 0 {
                mk += intMax
            }

            mj = seeds[ii]
        }

        for _ in 1..<5 {
            for i in 1..<56 {
                var n = i + 30
                if n >= 55 {
                    n -= 55
                }

                seeds[i] -= seeds[1 + n]
                if seeds[i] < 0 {
                    seeds[i] += intMax
                }
            }
        }
    }

    /// `Random.Next()`.
    mutating func next() -> Int {
        inext = inext + 1 >= 56 ? 1 : inext + 1
        inextp = inextp + 1 >= 56 ? 1 : inextp + 1
        var value = seeds[inext] - seeds[inextp]
        if value == Int(Int32.max) {
            value -= 1
        }

        if value < 0 {
            value += Int(Int32.max)
        }

        seeds[inext] = value
        return value
    }

    /// `Random.NextDouble()`.
    mutating func nextDouble() -> Double { Double(next()) * (1.0 / Double(Int32.max)) }

    /// `Random.Next(maxValue)`.
    mutating func next(_ maxValue: Int) -> Int { Int(nextDouble() * Double(maxValue)) }

    /// The harness's `Gen.Pick`.
    mutating func pick<T>(_ items: [T]) -> T { items[next(items.count)] }
}

/// The harness's escaping (session files, jarvis-core-harness): printable ASCII as is, a backslash doubled, anything
/// else as `\u{HEX}` scalar by scalar, and `\N` for null.
enum Escaped {
    static func decode(_ text: String) -> String? {
        if text == #"\N"# {
            return nil
        }

        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            if scalars[i] == "\\" && i + 1 < scalars.count && scalars[i + 1] == "\\" {
                out.append("\\")
                i += 2
            } else if scalars[i] == "\\" && i + 2 < scalars.count && scalars[i + 1] == "u" && scalars[i + 2] == "{",
                      let close = scalars[(i + 3)...].firstIndex(of: "}"),
                      let value = UInt32(String(String.UnicodeScalarView(scalars[(i + 3)..<close])), radix: 16),
                      let scalar = Unicode.Scalar(value) {
                out.append(scalar)
                i = close + 1
            } else {
                out.append(scalars[i])
                i += 1
            }
        }

        return String(out)
    }

    static func encode(_ text: String?) -> String {
        guard let text else { return #"\N"# }
        var out = ""
        for scalar in text.unicodeScalars {
            if scalar == "\\" {
                out += #"\\"#
            } else if scalar.value >= 0x20 && scalar.value < 0x7F {
                out.unicodeScalars.append(scalar)
            } else {
                out += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
            }
        }

        return out
    }
}
