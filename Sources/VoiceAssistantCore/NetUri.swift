import Foundation
import ThumbFreeCore

/// An http(s) address as .NET's `Uri` reads it, with the parts the assistant uses: `absoluteUri`, what Windows opens;
/// `host`, for messages ("Opening youtube.com…"); and `absolutePath` and `query`, since only a site's front page looks
/// for a tab that has it open. `url` is the same address for Foundation: the host in its IDN (Punycode) form, and the
/// brackets and extra number signs that `Uri` leaves as they are escaped.
public struct WebLink: Hashable, Sendable {
    /// `Uri.AbsoluteUri`.
    public let absoluteUri: String

    /// `Uri.Host`: composed (NFC), and in lower case when it has an upper-case ASCII letter.
    public let host: String

    /// `Uri.IdnHost`: the host in ASCII.
    public let idnHost: String

    /// `Uri.AbsolutePath`, escaped.
    public let absolutePath: String

    /// `Uri.Query`: "?" and what follows, escaped, or "".
    public let query: String

    /// `Uri.Fragment`: "#" and what follows, escaped, or "".
    public let fragment: String

    public let url: URL
}

/// How .NET's `Uri.TryCreate(text, UriKind.Absolute, out uri)` reads an http or https address with a DNS host (the only
/// kind BrainSafety opens), and how `AbsoluteUri` writes it back. Written from probes of .NET 10 and compared with it
/// on 400,000 generated addresses (jarvis-core-harness: UriModel.cs is this code in C#, UriCorpus.cs the comparison),
/// with no difference except two kinds of host this refuses: one where .NET's `IdnHost` throws `UriFormatException` (a
/// joiner, U+FFFD, a combining mark first in a label), and one whose IDN form isn't a DNS name, which .NET accepts (an
/// ideographic or no-break space inside it becomes an ASCII space).
enum NetUri {
    struct Parsed {
        let link: WebLink

        /// It has user information before an "@" ("user@example.com"), which BrainSafety refuses.
        let hasUserInfo: Bool
    }

    /// The address, or nil if it isn't an absolute http or https address with a DNS host.
    static func parse(_ text: String) -> Parsed? {
        let s = Array(text.unicodeScalars)
        guard let colon = s.firstIndex(of: ":"), colon > 0, isLetter(s[0]),
              s[..<colon].allSatisfy({ isLetter($0) || isDigit($0) || $0 == "+" || $0 == "-" || $0 == "." })
        else { return nil }

        let scheme = DotNet.lowerInvariant(DotNet.string(s[..<colon]))
        guard scheme == "http" || scheme == "https", colon + 2 < s.count, isSlash(s[colon + 1]), isSlash(s[colon + 2])
        else { return nil }

        // The authority runs to the path, query or fragment; a backslash right after it makes the address invalid.
        let start = colon + 3
        var end = start
        while end < s.count && !["/", "?", "#", "\\"].contains(s[end]) {
            end += 1
        }

        if end < s.count && s[end] == "\\" {
            return nil
        }

        let authority = Array(s[start..<end])
        let at = authority.firstIndex(of: "@")
        let hostPort = at.map { Array(authority[($0 + 1)...]) } ?? authority
        let portColon = hostPort.firstIndex(of: ":")
        let hostScalars = portColon.map { Array(hostPort[..<$0]) } ?? hostPort
        var port: Int?
        if let portColon, portColon + 1 < hostPort.count {
            var value = 0
            for c in hostPort[(portColon + 1)...] {
                guard isDigit(c) else { return nil }
                value = (value * 10) + Int(c.value) - 0x30
                if value > 65535 {
                    return nil
                }
            }

            port = value
        }

        guard let first = hostScalars.first, first != "[" else { return nil }
        guard let (host, idnHost) = readHost(hostScalars) else { return nil }

        let rest = Array(s[end...])
        var query = rest.firstIndex(of: "?")
        let hash = rest.firstIndex(of: "#")
        if let q = query, let h = hash, h < q {
            query = nil
        }

        let pathEnd = query ?? hash ?? rest.count
        let pathPart = rest[..<pathEnd].map { $0 == "\\" ? "/" : $0 }
        let queryPart = query.map { Array(rest[$0..<(hash ?? rest.count)]) } ?? []
        let fragmentPart = hash.map { Array(rest[$0...]) } ?? []
        let path = pathPart.isEmpty ? "/" : removeDotSegments(escape(pathPart, .path))
        let q = escape(queryPart, .query)
        let f = escape(fragmentPart, .fragment)
        let portText = port.map { $0 != (scheme == "http" ? 80 : 443) ? ":\($0)" : "" } ?? ""
        let userInfo = at.map { escape(Array(authority[..<$0]), .fragment) + "@" } ?? ""
        let absolute = scheme + "://" + userInfo + host + portText + path + q + f

        // Foundation wants the host in ASCII, and no [ ] or second # in the path, query or fragment.
        let fragmentTail = f.isEmpty ? "" : "#" + DotNet.replace(String(f.dropFirst()), "#", "%23")
        let foundation = scheme + "://" + idnHost + portText + escapeBrackets(path) + escapeBrackets(q)
            + escapeBrackets(fragmentTail)
        guard let url = URL(string: foundation) else { return nil }

        let link = WebLink(
            absoluteUri: absolute, host: host, idnHost: idnHost, absolutePath: path, query: q, fragment: f, url: url)
        return Parsed(link: link, hasUserInfo: (at ?? 0) > 0)
    }

    /// `Uri.Host` and `Uri.IdnHost`, or nil where `Uri` doesn't read a DNS name. `Uri` composes a host (NFC) first, so
    /// a Kelvin sign is a K; an ASCII host is a DNS name or nothing, and any other goes through IDN.
    private static func readHost(_ scalars: [Unicode.Scalar]) -> (String, String)? {
        let composed = scalars.allSatisfy(\.isASCII)
            ? scalars
            : Array(DotNet.string(scalars).precomposedStringWithCanonicalMapping.unicodeScalars)
        if composed.allSatisfy(\.isASCII) {
            let host = DotNet.lowerInvariant(DotNet.string(composed))
            return isDnsName(host) ? (host, host) : nil
        }

        let asciiOK = scalars.allSatisfy {
            !$0.isASCII || isLetter($0) || isDigit($0) || "-_.".unicodeScalars.contains($0)
        }
        guard asciiOK, let idn = idnHost(scalars) else { return nil }

        // Uri lowers the case of such a host only when it has an upper-case ASCII letter.
        let upper = composed.contains { ("A"..."Z").contains($0) }
        return (upper ? DotNet.lowerInvariant(DotNet.string(composed)) : DotNet.string(composed), idn)
    }

    /// Uri's DNS names: labels of letters, digits, hyphens and underscores that start with a letter or digit, at most
    /// 63 long, with one dot at the end allowed.
    static func isDnsName(_ host: String) -> Bool {
        let labels = host.unicodeScalars.split(separator: ".", omittingEmptySubsequences: false)
        for (i, label) in labels.enumerated() {
            if label.isEmpty {
                if i == labels.count - 1 && i > 0 {
                    continue
                }

                return false
            }

            guard label.count <= 63, let first = label.first, isLetter(first) || isDigit(first),
                  label.allSatisfy({ isLetter($0) || isDigit($0) || $0 == "-" || $0 == "_" })
            else { return false }
        }

        return true
    }

    // MARK: IDN

    /// The host's IDN form as Windows' IdnToAscii makes it, for the hosts compared: UTS 46's mapping (approximately,
    /// `uts46Map`), no label starting or ending with a hyphen, labels already in IDN form ("xn--…") checked by decoding
    /// them, others in Punycode. Nil where IdnToAscii fails or the result isn't a DNS name.
    private static func idnHost(_ host: [Unicode.Scalar]) -> String? {
        var result: [String] = []
        for label in uts46Map(host).unicodeScalars.split(separator: ".", omittingEmptySubsequences: false) {
            let scalars = Array(label)
            if scalars.first == "-" || scalars.last == "-" {
                return nil
            }

            if scalars.starts(with: "xn--".unicodeScalars) {
                let encoded = Array(scalars.dropFirst(4))
                guard let decoded = punycodeDecode(encoded), !decoded.allSatisfy(\.isASCII), isUnicodeLabel(decoded),
                      DotNet.ordinalEquals(uts46Map(decoded), DotNet.string(decoded)),
                      punycode(decoded).elementsEqual(encoded)
                else { return nil }
                result.append(DotNet.string(scalars))
            } else if scalars.allSatisfy(\.isASCII) {
                result.append(DotNet.string(scalars))
            } else {
                guard isUnicodeLabel(scalars) else { return nil }
                result.append("xn--" + DotNet.string(punycode(scalars)))
            }
        }

        let idn = result.joined(separator: ".")
        return isDnsName(idn) ? idn : nil
    }

    /// UTS 46's mapping, approximately: ideographic full stops as dots, invisible characters dropped, compatibility
    /// characters folded (NFKC: fullwidth "ｌｏｃａｌ" is "local"), lower case.
    private static func uts46Map(_ host: [Unicode.Scalar]) -> String {
        var mapped = String.UnicodeScalarView()
        for c in host {
            switch c.value {
            case 0x3002, 0xFF0E, 0xFF61:
                mapped.append(".")
            case 0xAD, 0x200B, 0x2060, 0xFEFF, 0x34F, 0xFE00...0xFE0F, 0x180B...0x180D:
                continue
            default:
                mapped.append(c)
            }
        }

        let folded = String(mapped).precomposedStringWithCompatibilityMapping
        return DotNet.lowerInvariant(folded).precomposedStringWithCompatibilityMapping
    }

    /// A label IdnToAscii takes: no combining mark first, and no joiners, controls, spaces, format or private-use
    /// characters, unassigned code points or U+FFFD.
    private static func isUnicodeLabel(_ scalars: [Unicode.Scalar]) -> Bool {
        guard let first = scalars.first else { return false }
        switch first.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return false
        default:
            break
        }

        return !scalars.contains { c in
            if c.value == 0x200C || c.value == 0x200D || c.value == 0xFFFD {
                return true
            }

            switch c.properties.generalCategory {
            case .control, .spaceSeparator, .lineSeparator, .paragraphSeparator, .format, .privateUse, .unassigned,
                 .surrogate:
                return true
            default:
                return false
            }
        }
    }

    private static let base = 36
    private static let tMin = 1
    private static let tMax = 26
    private static let skew = 38
    private static let damp = 700
    private static let initialBias = 72
    private static let initialN = 128

    /// RFC 3492's encoding of one label.
    static func punycode(_ input: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var output = input.filter(\.isASCII)
        let b = output.count
        var h = b
        if b > 0 {
            output.append("-")
        }

        var n = initialN
        var delta = 0
        var bias = initialBias
        while h < input.count {
            let m = input.lazy.map { Int($0.value) }.filter { $0 >= n }.min() ?? n
            delta += (m - n) * (h + 1)
            n = m
            for c in input {
                let value = Int(c.value)
                if value < n {
                    delta += 1
                }

                if value == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tMin : k >= bias + tMax ? tMax : k - bias
                        if q < t {
                            break
                        }

                        output.append(digit(t + ((q - t) % (base - t))))
                        q = (q - t) / (base - t)
                        k += base
                    }

                    output.append(digit(q))
                    bias = adapt(delta, h + 1, h == b)
                    delta = 0
                    h += 1
                }
            }

            delta += 1
            n += 1
        }

        return output
    }

    /// RFC 3492's decoding of one label, or nil if it isn't valid Punycode.
    static func punycodeDecode(_ input: [Unicode.Scalar]) -> [Unicode.Scalar]? {
        var output: [Int] = []
        let delimiter = input.lastIndex(of: "-") ?? 0
        if delimiter > 0 {
            for c in input[..<delimiter] {
                guard c.isASCII else { return nil }
                output.append(Int(c.value))
            }
        }

        var n = initialN
        var i = 0
        var bias = initialBias
        var position = delimiter > 0 ? delimiter + 1 : 0
        while position < input.count {
            let oldi = i
            var w = 1
            var k = base
            while true {
                guard position < input.count else { return nil }
                let c = input[position]
                position += 1
                let value = Int(c.value)
                let digit = (0x61...0x7A).contains(value) ? value - 0x61
                    : (0x30...0x39).contains(value) ? value - 0x30 + 26 : -1
                guard digit >= 0 else { return nil }
                i += digit * w
                guard i <= Int(Int32.max) else { return nil }
                let t = k <= bias ? tMin : k >= bias + tMax ? tMax : k - bias
                if digit < t {
                    break
                }

                w *= base - t
                guard w <= Int(Int32.max) else { return nil }
                k += base
            }

            bias = adapt(i - oldi, output.count + 1, oldi == 0)
            n += i / (output.count + 1)
            i %= output.count + 1
            guard n <= 0x10FFFF, !(0xD800...0xDFFF).contains(n) else { return nil }
            output.insert(n, at: i)
            i += 1
        }

        return output.compactMap { Unicode.Scalar(UInt32($0)) }
    }

    private static func digit(_ d: Int) -> Unicode.Scalar {
        Unicode.Scalar(UInt8(d < 26 ? 0x61 + d : 0x30 + d - 26))
    }

    private static func adapt(_ delta: Int, _ numPoints: Int, _ firstTime: Bool) -> Int {
        var delta = firstTime ? delta / damp : delta / 2
        delta += delta / numPoints
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }

        return k + (((base - tMin + 1) * delta) / (delta + skew))
    }

    // MARK: Path, query and fragment

    private enum Part {
        case path
        case query
        case fragment
    }

    /// How AbsoluteUri writes a path, query or fragment. An unreserved character escaped as %XX is unescaped. A valid
    /// UTF-8 escape of a character an IRI may hold (RFC 3987's ucschar, and iprivate in the query) gets upper-case hex;
    /// other escapes are kept as written, and a lone % is %25. Spaces, controls, " < > ^ ` { | }, a backslash outside
    /// the path (in the path it was made a slash) and everything outside ASCII are escaped as UTF-8.
    private static func escape(_ part: [Unicode.Scalar], _ kind: Part) -> String {
        var out = ""
        var i = 0
        while i < part.count {
            let c = part[i]
            if c == "%", i + 2 < part.count, let high = hex(part[i + 1]), let low = hex(part[i + 2]) {
                let value = (high << 4) | low
                if value < 0x80 {
                    if isUnreserved(value) {
                        out.unicodeScalars.append(Unicode.Scalar(UInt8(value)))
                    } else {
                        out.unicodeScalars.append(contentsOf: part[i...(i + 2)])
                    }

                    i += 3
                    continue
                }

                // A run of escapes that is the UTF-8 of one character: upper case if it may stay; otherwise as written.
                let length = (0xC2...0xDF).contains(value) ? 2 : (0xE0...0xEF).contains(value) ? 3
                    : (0xF0...0xF4).contains(value) ? 4 : 0
                var bytes = [UInt8(value)]
                for k in 1..<max(length, 1) {
                    let j = i + (3 * k)
                    if j + 2 < part.count, part[j] == "%", let h = hex(part[j + 1]), let l = hex(part[j + 2]) {
                        bytes.append(UInt8((h << 4) | l))
                    }
                }

                if length > 0, bytes.count == length, let scalar = decodeUTF8(bytes),
                   isIriChar(scalar, kind == .query) {
                    for byte in bytes {
                        out += percent(byte)
                    }

                    i += 3 * length
                } else {
                    out.unicodeScalars.append(contentsOf: part[i...(i + 2)])
                    i += 3
                }

                continue
            }

            if c == "%" {
                out += "%25"
            } else if !c.isASCII {
                for byte in String(c).utf8 {
                    out += percent(byte)
                }
            } else if c.value <= 0x20 || c.value == 0x7F || "\"<>^`{|}".unicodeScalars.contains(c)
                        || (c == "\\" && kind != .path) {
                out += percent(UInt8(c.value))
            } else {
                out.unicodeScalars.append(c)
            }

            i += 1
        }

        return out
    }

    /// RFC 3987's characters an IRI may hold as they are: only these are unescaped (and escaped again in upper case).
    private static func isIriChar(_ scalar: Unicode.Scalar, _ query: Bool) -> Bool {
        let c = scalar.value
        if c <= 0xFFFF {
            return (0xA0...0xD7FF).contains(c) || (0xF900...0xFDCF).contains(c) || (0xFDF0...0xFFEF).contains(c)
                || (query && (0xE000...0xF8FF).contains(c))
        }

        return (c & 0xFFFF) < 0xFFFE && !(0xE0000...0xE0FFF).contains(c) && (query || c < 0xF0000)
    }

    /// The character these 2 to 4 bytes are the well-formed UTF-8 of, or nil (Unicode's table 3-7).
    private static func decodeUTF8(_ bytes: [UInt8]) -> Unicode.Scalar? {
        let lead = bytes[0]
        let second: ClosedRange<UInt8> = lead == 0xE0 ? 0xA0...0xBF : lead == 0xED ? 0x80...0x9F
            : lead == 0xF0 ? 0x90...0xBF : lead == 0xF4 ? 0x80...0x8F : 0x80...0xBF
        guard bytes.count >= 2, second.contains(bytes[1]), bytes.dropFirst(2).allSatisfy({ (0x80...0xBF).contains($0) })
        else { return nil }

        var value = UInt32(lead) & (bytes.count == 2 ? 0x1F : bytes.count == 3 ? 0x0F : 0x07)
        for byte in bytes.dropFirst() {
            value = (value << 6) | (UInt32(byte) & 0x3F)
        }

        return Unicode.Scalar(value)
    }

    /// RFC 3986's remove_dot_segments, on an escaped (ASCII) path.
    private static func removeDotSegments(_ path: String) -> String {
        var input = Array(path.utf8)
        var output: [UInt8] = []
        let slash = UInt8(ascii: "/")
        let dot = UInt8(ascii: ".")
        func starts(_ prefix: String) -> Bool { input.starts(with: prefix.utf8) }
        func removeLastSegment() {
            output = output.lastIndex(of: slash).map { Array(output[..<$0]) } ?? []
        }

        while !input.isEmpty {
            if starts("../") {
                input.removeFirst(3)
            } else if starts("./") {
                input.removeFirst(2)
            } else if starts("/./") {
                input.removeFirst(2)
            } else if input == [slash, dot] {
                input = [slash]
            } else if starts("/../") {
                input.removeFirst(3)
                removeLastSegment()
            } else if input == [slash, dot, dot] {
                input = [slash]
                removeLastSegment()
            } else if input == [dot] || input == [dot, dot] {
                input = []
            } else {
                let next = input.dropFirst(input[0] == slash ? 1 : 0).firstIndex(of: slash) ?? input.count
                output.append(contentsOf: input[..<next])
                input.removeFirst(next)
            }
        }

        return String(decoding: output, as: UTF8.self)
    }

    private static func escapeBrackets(_ text: String) -> String {
        DotNet.replace(DotNet.replace(text, "[", "%5B"), "]", "%5D")
    }

    private static func percent(_ byte: UInt8) -> String {
        let digits = Array("0123456789ABCDEF".unicodeScalars)
        return "%" + String(digits[Int(byte >> 4)]) + String(digits[Int(byte & 0x0F)])
    }

    private static func isUnreserved(_ c: Int) -> Bool {
        (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) || (0x30...0x39).contains(c) || c == 0x2D || c == 0x2E
            || c == 0x5F || c == 0x7E
    }

    private static func hex(_ c: Unicode.Scalar) -> Int? {
        switch c.value {
        case 0x30...0x39: return Int(c.value) - 0x30
        case 0x41...0x46: return Int(c.value) - 0x41 + 10
        case 0x61...0x66: return Int(c.value) - 0x61 + 10
        default: return nil
        }
    }

    private static func isLetter(_ c: Unicode.Scalar) -> Bool { ("a"..."z").contains(c) || ("A"..."Z").contains(c) }

    private static func isDigit(_ c: Unicode.Scalar) -> Bool { ("0"..."9").contains(c) }

    private static func isSlash(_ c: Unicode.Scalar) -> Bool { c == "/" || c == "\\" }
}
