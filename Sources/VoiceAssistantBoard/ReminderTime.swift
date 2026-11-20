import Foundation

/// Finds a reminder time in spoken text and removes it from the task: "call mom tomorrow at 5 pm" → "call mom",
/// tomorrow 17:00. Understands "in 10 minutes / an hour / 2 days", "in half an hour", today / tonight / tomorrow / the
/// day after tomorrow, weekdays ("on Monday", "next Friday"), "at 5", "at 5:30 pm", "5 pm", noon, midnight, and
/// morning / afternoon / evening / night. Without am/pm, the next sensible time is used ("at 5" in the afternoon means
/// 5 pm).
///
/// `now` is a moment and `timeZone` its wall clock. C#'s `now` is a DateTimeOffset, which carries its own offset, and
/// its `zone` is the PC's; a `now` whose offset isn't the zone's keeps that fixed offset. Here that is a fixed-offset
/// `TimeZone(secondsFromGMT:)`.
public enum ReminderTime {
    public static func parse(
        _ text: String, now: Date, timeZone zone: TimeZone = .autoupdatingCurrent
    ) -> (task: String, due: Date?) {
        var work = amPmDots.replace(text) { DotNet.lowerInvariant($0[1] ?? "") + "m" }

        // "in 10 minutes", "after two hours", "in half an hour"
        var offset: TimeInterval?
        work = take(work, halfHour) { _ in offset = 30 * 60 }
        work = take(work, relative) { m in
            var amount = spaces.replace(DotNet.trim(m["n"] ?? "")) { _ in " " }
            if DotNet.startsWithOrdinalIgnoreCase(amount, "a ") {
                amount = String(String.UnicodeScalarView(amount.unicodeScalars.dropFirst(2))) // "a couple of", "a few"
            }

            // int.TryParse: ASCII digits that fit an Int32; anything else is a word, or 1.
            let n = Int32(amount).map { Int($0) } ?? numbers[DotNet.ordinalIgnoreCase(amount)] ?? 1
            let unit = DotNet.lowerInvariant(m["u"] ?? "")
            if DotNet.startsWith(unit, "min") {
                offset = TimeInterval(n * 60)
            } else if DotNet.startsWith(unit, "h") {
                offset = TimeInterval(n * 3600)
            } else if DotNet.startsWith(unit, "d") {
                offset = TimeInterval(n * 86_400)
            } else {
                offset = TimeInterval(7 * n * 86_400)
            }
        }

        if let offset {
            return (tidyTask(work), now.addingTimeInterval(offset))
        }

        let today = WallClock.day(of: now, in: zone)
        var dayOffset: Int?
        var defaultHour: Int?
        var partOfDay: String?
        work = take(work, day) { m in
            if let part = m["part"] {
                partOfDay = DotNet.lowerInvariant(part)
            }

            switch DotNet.lowerInvariant(m["day"] ?? "") {
            case "day after tomorrow":
                dayOffset = 2
            case "tomorrow":
                dayOffset = 1
            case "tonight":
                dayOffset = 0
                defaultHour = 20
            case "this evening":
                dayOffset = 0
                defaultHour = 18
            case "this afternoon":
                dayOffset = 0
                defaultHour = 15
            case "this morning":
                dayOffset = 0
                defaultHour = 9
            default:
                dayOffset = 0
            }
        }

        work = take(work, weekday) { m in
            // Enum.Parse<DayOfWeek>(name, ignoreCase: true): Sunday is 0; 1970-01-01, day 0, was a Thursday.
            let target = weekdays.firstIndex(of: DotNet.ordinalIgnoreCase(m["wd"] ?? "")) ?? 0
            let ahead = (target - Int(((today % 7) + 7 + 4) % 7) + 7) % 7
            dayOffset = ahead == 0 ? 7 : ahead
        }

        work = take(work, partOfDayWords) { m in partOfDay = DotNet.lowerInvariant(m["part"] ?? "") }

        var hour: Int?
        var minute = 0
        var ampm: String?
        work = take(work, noon) { m in
            let isNoon = DotNet.equalsOrdinalIgnoreCase(m["w"] ?? "", "noon")
            hour = isNoon ? 12 : 0
            ampm = isNoon ? "pm" : "am"
        }

        if hour == nil {
            work = take(work, clock) { m in
                hour = Int(m["h1"] ?? m["h2"] ?? m["h3"] ?? "")
                minute = Int(m["m1"] ?? m["m2"] ?? m["m3"] ?? "") ?? 0
                ampm = (m["ap1"] ?? m["ap2"]).map { DotNet.lowerInvariant($0) }
            }
        }

        let task = tidyTask(work)
        if dayOffset == nil && hour == nil && partOfDay == nil {
            return (task, nil)
        }

        let date = today + Int64(dayOffset ?? 0)
        guard let saidHour = hour else {
            let h: Int
            switch partOfDay ?? "" {
            case "morning": h = 9
            case "afternoon": h = 15
            case "evening": h = 18
            case "night": h = 21
            default: h = defaultHour ?? 9
            }

            let due = at(date, h, 0, in: zone)
            return (task, dayOffset == nil && due <= now ? due.addingTimeInterval(86_400) : due)
        }

        if saidHour < 0 || saidHour > 23 || minute < 0 || minute > 59 {
            return (task, nil)
        }

        var h24 = saidHour
        if ampm == "pm" && h24 < 12 {
            h24 += 12
        } else if ampm == "am" && h24 == 12 {
            h24 = 0
        } else if ampm == nil && h24 < 12 {
            if ["afternoon", "evening", "night"].contains(partOfDay ?? "") || (defaultHour ?? 0) >= 15 {
                h24 += 12
            } else if partOfDay == nil && dayOffset == nil {
                // "at 5": the next 5 o'clock (5 pm in the afternoon, 5 am tomorrow late at night).
                let am = at(date, h24, minute, in: zone)
                let pm = at(date, h24 + 12, minute, in: zone)
                return (task, am > now ? am : pm > now ? pm : am.addingTimeInterval(86_400))
            } else if partOfDay == nil && h24 < 7 {
                h24 += 12 // "tomorrow at 5" is 5 pm, not 5 am
            }
        }

        let result = at(date, h24, minute, in: zone)
        // A time that has passed is tomorrow's: 24 hours on, as C#'s DateTimeOffset.AddDays(1) (on the day the clocks
        // change, that's an hour off the time said).
        return (task, dayOffset == nil && result <= now ? result.addingTimeInterval(86_400) : result)
    }

    /// A wall-clock time on a day (days since 1970-01-01) in `zone`. The offset is the one in force then, so a reminder
    /// past a daylight-saving change still fires at the time said.
    private static func at(_ day: Int64, _ hour: Int, _ minute: Int, in zone: TimeZone) -> Date {
        var wall = day * 86_400 + Int64(hour * 3600 + minute * 60)
        if WallClock.isSkipped(wall, in: zone) {
            wall += 3600 // skipped by the spring change: the first moment that exists
        }

        return Date(timeIntervalSince1970: TimeInterval(wall - Int64(WallClock.utcOffset(atWall: wall, in: zone))))
    }

    private static func take(_ text: String, _ regex: DotNetRegex, _ found: (DotNetMatch) -> Void) -> String {
        guard let m = regex.match(text) else { return text }
        found(m)
        return m.string.replacingCharacters(in: m.result.range, with: " ")
    }

    private static func tidyTask(_ text: String) -> String {
        var t = DotNet.trim(DotNet.trim(multiSpace.replace(text) { _ in " " }), [",", ";", ":", ".", "!", " "])
        t = DotNet.trim(DotNet.trim(trailingLink.replace(t) { _ in "" }), [",", ";", ":", ".", " "])
        return t
    }

    /// C#'s `Numbers`, a dictionary with `StringComparer.OrdinalIgnoreCase`.
    private static let numbers: [[Unicode.Scalar]: Int] = Dictionary(uniqueKeysWithValues: [
        ("a", 1), ("an", 1), ("one", 1), ("two", 2), ("three", 3), ("four", 4), ("five", 5), ("six", 6),
        ("seven", 7), ("eight", 8), ("nine", 9), ("ten", 10), ("eleven", 11), ("twelve", 12), ("fifteen", 15),
        ("twenty", 20), ("thirty", 30), ("forty five", 45), ("forty-five", 45), ("couple of", 2), ("few", 3),
    ].map { (DotNet.ordinalIgnoreCase($0.0), $0.1) })

    private static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        .map { DotNet.ordinalIgnoreCase($0) }

    // MARK: Patterns: ReminderTime.cs's, with \b spelled out for ICU (see DotNetRegex)

    private static let wordStart = DotNetRegex.wordStart, wordEnd = DotNetRegex.wordEnd

    private static let spaces = DotNetRegex(#"\s+"#)

    private static let amPmDots = DotNetRegex(wordStart + #"([ap])\.\s?m\.?"#, ignoreCase: true)

    private static let halfHour = DotNetRegex(
        wordStart + #"(?:in|after)\s+half\s+an?\s+hour"# + wordEnd, ignoreCase: true)

    private static let relative = DotNetRegex(
        wordStart + #"(?:in|after)\s+(?<n>\d+|an?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve"#
            + #"|fifteen|twenty|thirty|forty[\s\-]five|a\s+couple\s+of|couple\s+of|a\s+few|few)"#
            + #"\s+(?<u>minutes?|mins?|hours?|hrs?|days?|weeks?)"# + wordEnd,
        ignoreCase: true)

    private static let day = DotNetRegex(
        wordStart + #"(?<day>day\s+after\s+tomorrow|tomorrow|today|tonight|this\s+evening|this\s+afternoon"#
            + #"|this\s+morning)(?:\s+(?<part>morning|afternoon|evening|night))?"# + wordEnd,
        ignoreCase: true)

    private static let weekday = DotNetRegex(
        wordStart + #"(?:on\s+|this\s+|next\s+|coming\s+)?(?<wd>monday|tuesday|wednesday|thursday|friday|saturday"#
            + #"|sunday)"# + wordEnd,
        ignoreCase: true)

    private static let partOfDayWords = DotNetRegex(
        wordStart + #"(?:in\s+the\s+|at\s+)(?<part>morning|afternoon|evening|night)"# + wordEnd, ignoreCase: true)

    private static let noon = DotNetRegex(wordStart + #"(?:at\s+)?(?<w>noon|midnight)"# + wordEnd, ignoreCase: true)

    // "at 5", "at 5:30", "5 pm", "5:30 pm", "17:00" (a bare number needs "at" or am/pm, so "call 3 people" stays).
    // The hours and minutes are ASCII digits: C#'s \d also takes other scripts' digits, which int.Parse then rejects
    // with an exception.
    private static let clock = DotNetRegex(
        wordStart + #"(?:at\s+(?<h1>[0-9]{1,2})(?:[.:](?<m1>[0-9]{2}))?(?:\s*(?<ap1>am|pm))?"#
            + #"|(?<h2>[0-9]{1,2})(?:[.:](?<m2>[0-9]{2}))?\s*(?<ap2>am|pm)|(?<h3>[0-9]{1,2}):(?<m3>[0-9]{2}))"#
            + wordEnd,
        ignoreCase: true)

    private static let multiSpace = DotNetRegex(#"\s{2,}"#)

    private static let trailingLink = DotNetRegex(wordStart + #"(?:at|on|by|in|for|from)\s*$"#, ignoreCase: true)
}
