import Foundation

/// How far back "Custom Review" looks.
///
/// This is a scope the user picks, not a grouping the app infers — it says nothing
/// about which photos resemble each other (see decision #1 in `docs/DECISIONS.md`).
public enum ReviewPeriod: CaseIterable, Sendable, Equatable {
    case lastWeek
    case lastMonth
    case lastThreeMonths

    public var title: String {
        switch self {
        case .lastWeek: "Last week"
        case .lastMonth: "Last month"
        case .lastThreeMonths: "Last 3 months"
        }
    }

    /// The earliest creation date this period includes, counting back from `now`.
    ///
    /// Rolling, not calendar-aligned: "last week" is the past seven days, not
    /// Monday to Sunday. Month arithmetic is left to `Calendar`, which clamps at
    /// month ends (31 March minus a month is 28 February).
    public func startDate(relativeTo now: Date, calendar: Calendar = .current) -> Date {
        let (component, value): (Calendar.Component, Int) = switch self {
        case .lastWeek: (.day, -7)
        case .lastMonth: (.month, -1)
        case .lastThreeMonths: (.month, -3)
        }
        return calendar.date(byAdding: component, value: value, to: now) ?? now
    }

    /// Whether a photo taken at `creationDate` falls inside this period.
    ///
    /// A photo with no date is left out rather than guessed at. Nothing is
    /// excluded for being *after* `now` — a wrong camera clock stamps recent
    /// photos slightly in the future, and those belong in.
    public func includes(
        _ creationDate: Date?,
        relativeTo now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard let creationDate else { return false }
        return creationDate >= startDate(relativeTo: now, calendar: calendar)
    }
}
