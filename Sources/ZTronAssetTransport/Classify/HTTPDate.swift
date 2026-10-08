import Foundation

/// The three HTTP-date formats of RFC 9110 §5.6.7, which a recipient "MUST accept": IMF-fixdate
/// (`Sun, 06 Nov 1994 08:49:37 GMT`), the obsolete RFC 850 form (`Sunday, 06-Nov-94 08:49:37 GMT`) and asctime
/// (`Sun Nov  6 08:49:37 1994`).
///
/// Hand-written over bytes: `DateFormatter` depends on locale and allocates, and `Regex` is not available at the
/// iOS 15 floor. Names are case-sensitive as the grammar says; the weekday is checked for form only, never against
/// the date (a wrong weekday is a sender bug that changes nothing about the instant). An RFC 850 two-digit year is
/// read as 2000–2068 or 1969–1999, the fixed pivot Python's `email.utils` uses: RFC 9110's "more than 50 years in
/// the future" rule needs the current date, and the transport never reads a clock (H-8).
enum HTTPDate {
    /// Seconds since 1970 for a well-formed date, else `nil`.
    static func parse(_ bytes: [UInt8]) -> Int64? {
        if let seconds = Self.imfFixdate(bytes) {
            return seconds
        }
        if let seconds = Self.rfc850(bytes) {
            return seconds
        }
        return Self.asctime(bytes)
    }

    private static let shortDays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let longDays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// `Sun, 06 Nov 1994 08:49:37 GMT`: exactly 29 bytes.
    private static func imfFixdate(_ b: [UInt8]) -> Int64? {
        guard b.count == 29, Self.shortDays.contains(Self.text(b, 0, 3)), b[3] == UInt8(ascii: ","),
            b[4] == 0x20, b[7] == 0x20, b[11] == 0x20, b[16] == 0x20, b[25] == 0x20, Self.text(b, 26, 3) == "GMT",
            let day = Self.number(b, 5, 2), let month = Self.month(b, 8), let year = Self.number(b, 12, 4),
            let time = Self.time(b, 17)
        else {
            return nil
        }
        return Self.epochSeconds(year: year, month: month, day: day, time: time)
    }

    /// `Sunday, 06-Nov-94 08:49:37 GMT`: a full weekday name, then 24 fixed bytes.
    private static func rfc850(_ b: [UInt8]) -> Int64? {
        guard let comma = b.firstIndex(of: UInt8(ascii: ",")), Self.longDays.contains(Self.text(b, 0, comma)) else {
            return nil
        }
        let s = comma + 2
        guard b.count == s + 22, b[comma + 1] == 0x20, b[s + 2] == UInt8(ascii: "-"), b[s + 6] == UInt8(ascii: "-"),
            b[s + 9] == 0x20, b[s + 18] == 0x20, Self.text(b, s + 19, 3) == "GMT",
            let day = Self.number(b, s, 2), let month = Self.month(b, s + 3), let shortYear = Self.number(b, s + 7, 2),
            let time = Self.time(b, s + 10)
        else {
            return nil
        }
        let year = shortYear <= 68 ? 2000 + shortYear : 1900 + shortYear
        return Self.epochSeconds(year: year, month: month, day: day, time: time)
    }

    /// `Sun Nov  6 08:49:37 1994`: exactly 24 bytes, the day padded with a space or a zero.
    private static func asctime(_ b: [UInt8]) -> Int64? {
        guard b.count == 24, Self.shortDays.contains(Self.text(b, 0, 3)), b[3] == 0x20, b[7] == 0x20, b[10] == 0x20,
            b[19] == 0x20, let month = Self.month(b, 4), let time = Self.time(b, 11), let year = Self.number(b, 20, 4)
        else {
            return nil
        }
        let day: Int?
        if b[8] == 0x20 {
            day = Self.number(b, 9, 1)
        } else {
            day = Self.number(b, 8, 2)
        }
        guard let day else {
            return nil
        }
        return Self.epochSeconds(year: year, month: month, day: day, time: time)
    }

    /// The bytes at `start..<start + count` as text (empty or short past the end, never a trap).
    private static func text(_ b: [UInt8], _ start: Int, _ count: Int) -> String {
        String(decoding: b.dropFirst(start).prefix(count), as: UTF8.self)
    }

    /// `count` decimal digits at `start`, else `nil`.
    private static func number(_ b: [UInt8], _ start: Int, _ count: Int) -> Int? {
        let digits = b.dropFirst(start).prefix(count)
        guard digits.count == count, digits.allSatisfy({ (0x30...0x39).contains($0) }) else {
            return nil
        }
        return digits.reduce(0) { $0 * 10 + Int($1 - 0x30) }
    }

    private static func month(_ b: [UInt8], _ start: Int) -> Int? {
        Self.months.firstIndex(of: Self.text(b, start, 3)).map { $0 + 1 }
    }

    /// `HH:MM:SS` → seconds of the day; a leap second (60) is accepted, as the grammar allows.
    private static func time(_ b: [UInt8], _ start: Int) -> Int? {
        guard b.count >= start + 8, b[start + 2] == UInt8(ascii: ":"), b[start + 5] == UInt8(ascii: ":"),
            let hour = Self.number(b, start, 2), let minute = Self.number(b, start + 3, 2),
            let second = Self.number(b, start + 6, 2), hour <= 23, minute <= 59, second <= 60
        else {
            return nil
        }
        return hour * 3_600 + minute * 60 + second
    }

    /// Days from the civil calendar (Howard Hinnant's `days_from_civil`), validating the day of the month.
    private static func epochSeconds(year: Int, month: Int, day: Int, time: Int) -> Int64? {
        guard (1...12).contains(month), day >= 1, day <= Self.daysIn(month: month, year: year), year >= 1 else {
            return nil
        }
        let y = month <= 2 ? year - 1 : year
        let era = y / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        return Int64(days) * 86_400 + Int64(time)
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }
}
