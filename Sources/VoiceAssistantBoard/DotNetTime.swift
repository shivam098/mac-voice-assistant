import Foundation

/// .NET's `DateTimeOffset`, as board.json stores times: a wall-clock time in 100-ns ticks since 0001-01-01, and the
/// offset from UTC in minutes. The store keeps the times it reads this way, so Windows' times are written back exactly:
/// a `Date` holds neither the offset nor every tick.
struct DateTimeOffset: Equatable {
    static let ticksPerSecond: Int64 = 10_000_000
    static let ticksPerDay: Int64 = 864_000_000_000

    /// `DateTimeOffset.MaxValue.Ticks`: 9999-12-31T23:59:59.9999999.
    static let maxTicks: Int64 = 3_155_378_975_999_999_999

    /// Foundation's reference date, 2001-01-01T00:00:00Z.
    static let referenceDateTicks: Int64 = 631_139_040_000_000_000

    /// `default(DateTimeOffset)`, 0001-01-01T00:00:00+00:00.
    static let zero = DateTimeOffset(ticks: 0, offsetMinutes: 0)

    /// Ticks on the wall clock, from 0 to `maxTicks`.
    let ticks: Int64

    /// Minutes east of UTC, within ±14 hours.
    let offsetMinutes: Int

    init(ticks: Int64, offsetMinutes: Int) {
        self.ticks = ticks
        self.offsetMinutes = offsetMinutes
    }

    /// `date` with `offsetMinutes`, to the microsecond (in this century a `Date` holds about a tenth of one), and kept
    /// to the years .NET can hold, 1 to 9999: in UTC if the wall clock would be outside them.
    init(_ date: Date, offsetMinutes: Int) {
        let seconds = date.timeIntervalSinceReferenceDate
        var utc: Int64
        if !(seconds >= -63_113_904_000) {
            utc = 0
        } else if seconds >= 252_423_993_600 {
            utc = Self.maxTicks
        } else {
            let whole = seconds.rounded(.down)
            let microseconds = Int64(((seconds - whole) * 1_000_000).rounded())
            utc = Self.referenceDateTicks + Int64(whole) * Self.ticksPerSecond + microseconds * 10
        }

        utc = min(max(utc, 0), Self.maxTicks)
        let local = utc + Int64(offsetMinutes) * 60 * Self.ticksPerSecond
        if abs(offsetMinutes) <= 14 * 60 && local >= 0 && local <= Self.maxTicks {
            self.init(ticks: local, offsetMinutes: offsetMinutes)
        } else {
            self.init(ticks: utc, offsetMinutes: 0)
        }
    }

    /// `date` with the offset `zone` has at that moment.
    init(_ date: Date, in zone: TimeZone) {
        self.init(date, offsetMinutes: Int((Double(zone.secondsFromGMT(for: date)) / 60).rounded()))
    }

    /// The moment, as the nearest `Date`.
    var date: Date {
        let utc = ticks - Int64(offsetMinutes) * 60 * Self.ticksPerSecond
        var (seconds, fraction) = (utc - Self.referenceDateTicks).quotientAndRemainder(dividingBy: Self.ticksPerSecond)
        if fraction < 0 {
            seconds -= 1
            fraction += Self.ticksPerSecond
        }

        return Date(timeIntervalSinceReferenceDate: Double(seconds) + Double(fraction) / Double(Self.ticksPerSecond))
    }

    /// The wall-clock time as `yyyyMMddHHmmss`.
    var compact: String { String(iso.prefix(19).filter { $0 != "-" && $0 != "T" && $0 != ":" }) }

    /// System.Text.Json's way of writing it: "2026-11-11T14:30:12.3456789+05:30", with no trailing zeros in the
    /// fraction (and no fraction for whole seconds).
    var iso: String {
        let (days, time) = ticks.quotientAndRemainder(dividingBy: Self.ticksPerDay)
        let date = Civil.date(fromDays: Int(days) - Civil.daysFrom0001To1970)
        let seconds = Int(time / Self.ticksPerSecond)
        let (hour, minute, second) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        var text = "\(Self.digits(date.year, 4))-\(Self.digits(date.month, 2))-\(Self.digits(date.day, 2))"
        text += "T\(Self.digits(hour, 2)):\(Self.digits(minute, 2)):\(Self.digits(second, 2))"
        var fraction = Self.digits(Int(time % Self.ticksPerSecond), 7)
        while fraction.hasSuffix("0") {
            fraction.removeLast()
        }

        if !fraction.isEmpty {
            text += "." + fraction
        }

        let offset = abs(offsetMinutes)
        let sign = offsetMinutes < 0 ? "-" : "+"
        return "\(text)\(sign)\(Self.digits(offset / 60, 2)):\(Self.digits(offset % 60, 2))"
    }

    /// System.Text.Json's ISO 8601 reader (`JsonHelpers.TryParseAsISO`): "yyyy-MM-dd", then optionally "THH:mm",
    /// ":ss" and a fraction of up to 16 digits (7 kept), then "Z", "±HH" or "±HH:mm". "T24:00:00", the end of a day,
    /// is the next midnight. A time without an offset is local, in `zone` (the PC's time zone in C#). Nil where
    /// System.Text.Json throws.
    init?(iso text: String, localZone zone: TimeZone) {
        guard let parts = Self.parts(Array(text.utf8)), parts.year > 0, (1...12).contains(parts.month),
              (1...Civil.daysInMonth(parts.year, parts.month)).contains(parts.day), parts.minute <= 59,
              parts.second <= 59
        else { return nil }

        let endOfDay = parts.hour == 24 && parts.minute == 0 && parts.second == 0 && parts.fraction == 0
        guard parts.hour <= 23 || endOfDay else { return nil }
        let date = Civil.days(year: parts.year, month: parts.month, day: parts.day) + (endOfDay ? 1 : 0)
        let days = Int64(date + Civil.daysFrom0001To1970)
        let seconds = Int64((endOfDay ? 0 : parts.hour) * 3600 + parts.minute * 60 + parts.second)
        let ticks = days * Self.ticksPerDay + seconds * Self.ticksPerSecond + Int64(parts.fraction)
        guard ticks <= Self.maxTicks else { return nil }
        var offsetMinutes: Int
        if let offset = parts.offset {
            guard offset.hours <= 14, offset.minutes <= 59, offset.hours < 14 || offset.minutes == 0 else { return nil }
            offsetMinutes = offset.hours * 60 + offset.minutes
            if offset.negative {
                offsetMinutes = -offsetMinutes
            }
        } else {
            offsetMinutes = WallClock.utcOffset(atWall: Int64(date) * 86_400 + seconds, in: zone) / 60
        }

        let utc = ticks - Int64(offsetMinutes) * 60 * Self.ticksPerSecond
        guard utc >= 0 && utc <= Self.maxTicks else { return nil }
        self.init(ticks: ticks, offsetMinutes: offsetMinutes)
    }

    private struct Parts {
        var year = 0, month = 0, day = 0, hour = 0, minute = 0, second = 0, fraction = 0
        var offset: (negative: Bool, hours: Int, minutes: Int)?
    }

    private static let hyphen = UInt8(ascii: "-"), plus = UInt8(ascii: "+"), colon = UInt8(ascii: ":")
    private static let period = UInt8(ascii: "."), letterT = UInt8(ascii: "T"), letterZ = UInt8(ascii: "Z")

    /// The fields of an ISO 8601 date, read as `JsonHelpers.TryParseDateTimeOffset` reads them.
    private static func parts(_ s: [UInt8]) -> Parts? {
        guard s.count >= 10 && s.count <= 42 else { return nil }
        var parts = Parts()
        guard let year = number(s, 0, 4), s[4] == hyphen, let month = number(s, 5, 2), s[7] == hyphen,
              let day = number(s, 8, 2)
        else { return nil }

        (parts.year, parts.month, parts.day) = (year, month, day)
        if s.count == 10 {
            return parts
        }

        guard s.count >= 16, s[10] == letterT, s[13] == colon, let hour = number(s, 11, 2),
              let minute = number(s, 14, 2)
        else { return nil }

        (parts.hour, parts.minute) = (hour, minute)
        if s.count == 16 {
            return parts
        }

        switch s[16] {
        case letterZ: return s.count == 17 ? withOffset(parts, negative: false, 0, 0) : nil
        case plus, hyphen: return offset(s, from: 17, negative: s[16] == hyphen, parts)
        case colon: break
        default: return nil
        }

        guard s.count >= 19, let second = number(s, 17, 2) else { return nil }
        parts.second = second
        if s.count == 19 {
            return parts
        }

        switch s[19] {
        case letterZ: return s.count == 20 ? withOffset(parts, negative: false, 0, 0) : nil
        case plus, hyphen: return offset(s, from: 20, negative: s[19] == hyphen, parts)
        case period: break
        default: return nil
        }

        guard s.count >= 21 else { return nil }
        var index = 20
        var read = 0
        let end = min(index + 16, s.count)
        while index < end, let digit = number(s, index, 1) {
            if read < 7 {
                parts.fraction = parts.fraction * 10 + digit
                read += 1
            }

            index += 1
        }

        if parts.fraction != 0 {
            while read < 7 {
                parts.fraction *= 10
                read += 1
            }
        }

        if index == s.count {
            return parts
        }

        switch s[index] {
        case letterZ: return index + 1 == s.count ? withOffset(parts, negative: false, 0, 0) : nil
        case plus, hyphen: return offset(s, from: index + 1, negative: s[index] == hyphen, parts)
        default: return nil
        }
    }

    /// "HH" or "HH:mm" to the end of the text.
    private static func offset(_ s: [UInt8], from start: Int, negative: Bool, _ parts: Parts) -> Parts? {
        let length = s.count - start
        guard length >= 2, let hours = number(s, start, 2) else { return nil }
        if length == 2 {
            return withOffset(parts, negative: negative, hours, 0)
        }

        guard length == 5, s[start + 2] == colon, let minutes = number(s, start + 3, 2) else { return nil }
        return withOffset(parts, negative: negative, hours, minutes)
    }

    private static func withOffset(_ parts: Parts, negative: Bool, _ hours: Int, _ minutes: Int) -> Parts {
        var result = parts
        result.offset = (negative, hours, minutes)
        return result
    }

    /// The ASCII digits at `start` as a number, or nil.
    private static func number(_ s: [UInt8], _ start: Int, _ count: Int) -> Int? {
        guard start >= 0 && start + count <= s.count else { return nil }
        var value = 0
        for byte in s[start..<(start + count)] {
            guard byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }

        return value
    }

    private static func digits(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }
}

/// Dates on the proleptic Gregorian calendar as day numbers, as .NET's `DateTime` counts them (Foundation's Gregorian
/// calendar is Julian before October 1582). Howard Hinnant's `days_from_civil` and `civil_from_days`.
enum Civil {
    static let daysFrom0001To1970 = 719_162

    /// Days since 1970-01-01.
    static func days(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The date `days` after 1970-01-01.
    static func date(fromDays days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    static func daysInMonth(_ year: Int, _ month: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }
}

/// Wall-clock times in a time zone, read as .NET's `TimeZoneInfo` reads them. `wall` is seconds since 1970-01-01 on
/// that wall clock.
enum WallClock {
    /// `TimeZoneInfo.IsInvalidTime`: the clocks skip `wall` (it falls in the hour lost when they go forward).
    static func isSkipped(_ wall: Int64, in zone: TimeZone) -> Bool { offsets(atWall: wall, in: zone).isEmpty }

    /// `TimeZoneInfo.GetUtcOffset` for a wall-clock time, in seconds: standard time for a time that happens twice
    /// (when the clocks go back) or never (when they go forward).
    static func utcOffset(atWall wall: Int64, in zone: TimeZone) -> Int {
        let valid = offsets(atWall: wall, in: zone)
        switch valid.count {
        case 0: return zone.secondsFromGMT(for: instant(wall - 86_400))
        case 1: return valid[0]
        default:
            let standard = valid.first(where: { !zone.isDaylightSavingTime(for: instant(wall - Int64($0))) })
            return standard ?? valid[valid.count - 1]
        }
    }

    /// The day number (days since 1970-01-01) of the wall-clock date at `date` in `zone` (`now.Date`).
    static func day(of date: Date, in zone: TimeZone) -> Int64 {
        Int64(((date.timeIntervalSince1970 + Double(zone.secondsFromGMT(for: date))) / 86_400).rounded(.down))
    }

    /// The offsets `zone` can have at `wall`: one, none in the hour skipped when clocks go forward, two in the hour
    /// repeated when they go back. Clocks change at most once in the two days around a time.
    private static func offsets(atWall wall: Int64, in zone: TimeZone) -> [Int] {
        let before = zone.secondsFromGMT(for: instant(wall - 86_400))
        let after = zone.secondsFromGMT(for: instant(wall + 86_400))
        let candidates = before == after ? [before] : [before, after]
        return candidates.filter { zone.secondsFromGMT(for: instant(wall - Int64($0))) == $0 }
    }

    private static func instant(_ secondsSince1970: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(secondsSince1970))
    }
}
