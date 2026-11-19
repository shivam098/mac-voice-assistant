import XCTest
@testable import VoiceAssistantBoard

/// Edge cases beyond the C# tests, with the results windows-voice-assistant's ReminderTime.cs gives for them (worked
/// out by running it): around midnight, at the ends of months and years, a weekday said on that weekday, and
/// daylight saving changes.
final class ReminderTimeEdgeTests: XCTestCase {
    private func check(
        _ spoken: String, said: Date, due: Date?, in zone: TimeZone = india,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(ReminderTime.parse(spoken, now: said, timeZone: zone).due, due, spoken, file: file, line: line)
    }

    func testAroundMidnight() {
        check("back up the laptop at midnight", said: moment(2026, 11, 11, 23, 59), due: moment(2026, 11, 12, 0, 0))
        // At midnight, "at midnight" is the next one.
        check("back up the laptop at midnight", said: moment(2026, 11, 12, 0, 0), due: moment(2026, 11, 13, 0, 0))
        check("call mom tomorrow", said: moment(2026, 11, 11, 23, 30), due: moment(2026, 11, 12, 9, 0))
        check("pay rent at 6", said: moment(2026, 11, 12, 0, 10), due: moment(2026, 11, 12, 6, 0))
        check("lunch at 12", said: moment(2026, 11, 11, 23, 30), due: moment(2026, 11, 12, 12, 0))
        check("call at 11", said: moment(2026, 11, 11, 23, 30), due: moment(2026, 11, 12, 11, 0))
        check("call at 11:45", said: moment(2026, 11, 11, 23, 30), due: moment(2026, 11, 11, 23, 45))
        check("call mom tomorrow at 12 am", said: moment(2026, 11, 11, 10, 0), due: moment(2026, 11, 12, 0, 0))
        check("call mom at 12 pm", said: moment(2026, 11, 11, 10, 0), due: moment(2026, 11, 11, 12, 0))
        // "Tonight" is 8 pm today, even when that has passed.
        check("take medicine tonight", said: moment(2026, 11, 11, 23, 30), due: moment(2026, 11, 11, 20, 0))
    }

    func testEndsOfMonthsAndYears() {
        check("call mom tomorrow at 9", said: moment(2026, 11, 30, 22, 0), due: moment(2026, 12, 1, 9, 0))
        check("pay rent at 6", said: moment(2026, 12, 31, 20, 0), due: moment(2027, 1, 1, 6, 0))
        check("visit the day after tomorrow", said: moment(2026, 12, 31, 10, 0), due: moment(2027, 1, 2, 9, 0))
        check("send the invoice tomorrow", said: moment(2028, 2, 28, 10, 0), due: moment(2028, 2, 29, 9, 0))
        check("send the invoice tomorrow", said: moment(2027, 2, 28, 10, 0), due: moment(2027, 3, 1, 9, 0))
        check("review the deck on Friday", said: moment(2026, 11, 30, 10, 0), due: moment(2026, 12, 4, 9, 0))
        check("follow up in 2 days", said: moment(2026, 11, 30, 14, 30), due: moment(2026, 12, 2, 14, 30))
        check("follow up in a week", said: moment(2026, 12, 28, 14, 30), due: moment(2027, 1, 4, 14, 30))
    }

    func testAWeekdaySaidOnThatDayIsAWeekAway() {
        let monday = moment(2026, 11, 16, 10, 0)
        check("team lunch next Monday", said: monday, due: moment(2026, 11, 23, 9, 0))
        check("team lunch on Monday", said: monday, due: moment(2026, 11, 23, 9, 0))
        check("team lunch this Monday", said: monday, due: moment(2026, 11, 23, 9, 0))
        // Even before the time said.
        check("standup Monday at 8 am", said: moment(2026, 11, 16, 7, 0), due: moment(2026, 11, 23, 8, 0))
        check("call on Sunday", said: monday, due: moment(2026, 11, 22, 9, 0))
        check("call on Tuesday", said: monday, due: moment(2026, 11, 17, 9, 0))
        check("call on Saturday at 3", said: monday, due: moment(2026, 11, 21, 15, 0))
    }

    func testDaylightSavingChanges() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        func pst(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            moment(year, month, day, hour, minute, in: offset(hours: -8))
        }

        func pdt(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            moment(year, month, day, hour, minute, in: offset(hours: -7))
        }

        // 2:30 am doesn't happen on 14 March 2027 (clocks go from 2:00 to 3:00): the first moment that does, 3:30.
        check("check the boiler tomorrow at 2:30 am", said: pst(2027, 3, 13, 10), due: pdt(2027, 3, 14, 3, 30),
              in: zone)
        check("water the plants at 2", said: pst(2027, 3, 14, 1, 30), due: pdt(2027, 3, 14, 3), in: zone)
        // 1:30 am happens twice on 1 November 2026 (clocks go from 2:00 back to 1:00): standard time, the second.
        check("check the boiler tomorrow at 1:30 am", said: pdt(2026, 10, 31, 10), due: pst(2026, 11, 1, 1, 30),
              in: zone)
        check("water the plants at 1:30", said: pdt(2026, 11, 1, 0, 30), due: pst(2026, 11, 1, 1, 30), in: zone)
        // A relative time is a length of time.
        check("follow up in 2 days", said: pst(2027, 3, 13, 10), due: pst(2027, 3, 15, 10), in: zone)
        // A time of day that has passed moves on 24 hours, as C#'s DateTimeOffset.AddDays(1) does: across the spring
        // change, 6 pm becomes 7 pm.
        check("gym in the evening", said: pst(2027, 3, 13, 19), due: pst(2027, 3, 14, 18), in: zone)
    }

    func testOtherPhrasings() {
        let now = moment(2026, 11, 11, 14, 30)
        check("pay rent by tomorrow", said: now, due: moment(2026, 11, 12, 9, 0))
        check("gym tomorrow evening at 7", said: now, due: moment(2026, 11, 12, 19, 0))
        check("call at 6 in the morning", said: now, due: moment(2026, 11, 12, 6, 0))
        check("call at 9 at night", said: now, due: moment(2026, 11, 11, 21, 0))
        check("call tomorrow at 6", said: now, due: moment(2026, 11, 12, 18, 0))
        check("call tomorrow at 7", said: now, due: moment(2026, 11, 12, 7, 0))
        check("call this afternoon at 4", said: now, due: moment(2026, 11, 11, 16, 0))
        check("call mom at 5 tomorrow", said: now, due: moment(2026, 11, 12, 17, 0))
        check("call on friday at 5:30pm", said: now, due: moment(2026, 11, 13, 17, 30))
        check("pay rent next friday at noon", said: now, due: moment(2026, 11, 13, 12, 0))
        check("call at midnight tomorrow", said: now, due: moment(2026, 11, 12, 0, 0))
        check("meet at 5.30 pm", said: now, due: moment(2026, 11, 11, 17, 30))
        check("meet at 5 P.M.", said: now, due: moment(2026, 11, 11, 17, 0))
        check("meet at 17 pm", said: now, due: moment(2026, 11, 11, 17, 0))
        check("meet at 0", said: now, due: moment(2026, 11, 12, 0, 0))
        check("stretch in forty-five minutes", said: now, due: moment(2026, 11, 11, 15, 15))
        check("Stretch In An Hour", said: now, due: moment(2026, 11, 11, 15, 30))
        // An amount that isn't a number C# can read counts as 1.
        check("stretch in 99999999999 minutes", said: now, due: moment(2026, 11, 11, 14, 31))
        check("stretch in \u{967}\u{966} minutes", said: now, due: moment(2026, 11, 11, 14, 31))
        // No time at all.
        check("meet at 25", said: now, due: nil)
        check("meet at 5:75", said: now, due: nil)
        check("meet at 530", said: now, due: nil)
        check("stretch in forty  five minutes", said: now, due: nil)
        // Deviation: a clock time in other digits is no time here; C#'s int.Parse throws a FormatException on it.
        check("call at \u{967}\u{966} pm", said: now, due: nil)
        XCTAssertEqual(ReminderTime.parse("visit the day after tomorrow", now: now, timeZone: india).task, "visit the")
        let early = ReminderTime.parse("in 10 minutes call mom tomorrow", now: now, timeZone: india)
        XCTAssertEqual(early.task, "call mom tomorrow")
    }
}
