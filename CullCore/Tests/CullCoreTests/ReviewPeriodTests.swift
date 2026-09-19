import XCTest
@testable import CullCore

final class ReviewPeriodTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testOffersTheThreePeriodsInOrder() {
        XCTAssertEqual(ReviewPeriod.allCases, [.lastWeek, .lastMonth, .lastThreeMonths])
        XCTAssertEqual(ReviewPeriod.allCases.map(\.title), ["Last week", "Last month", "Last 3 months"])
    }

    func testLastWeekStartsSevenDaysBack() {
        let now = date(2026, 9, 19)
        XCTAssertEqual(ReviewPeriod.lastWeek.startDate(relativeTo: now, calendar: calendar), date(2026, 9, 12))
    }

    func testLastMonthAndThreeMonthsStartByCalendarMonths() {
        let now = date(2026, 9, 19)
        XCTAssertEqual(ReviewPeriod.lastMonth.startDate(relativeTo: now, calendar: calendar), date(2026, 8, 19))
        XCTAssertEqual(ReviewPeriod.lastThreeMonths.startDate(relativeTo: now, calendar: calendar), date(2026, 6, 19))
    }

    /// There is no 31 February — the calendar clamps rather than skipping ahead.
    func testMonthEndClampsToTheShorterMonth() {
        XCTAssertEqual(
            ReviewPeriod.lastMonth.startDate(relativeTo: date(2026, 3, 31), calendar: calendar),
            date(2026, 2, 28)
        )
        XCTAssertEqual(
            ReviewPeriod.lastThreeMonths.startDate(relativeTo: date(2026, 5, 31), calendar: calendar),
            date(2026, 2, 28)
        )
    }

    func testCutoffIsInclusiveAndOneSecondEarlierIsOut() {
        let now = date(2026, 9, 19)
        let cutoff = ReviewPeriod.lastWeek.startDate(relativeTo: now, calendar: calendar)

        XCTAssertTrue(ReviewPeriod.lastWeek.includes(cutoff, relativeTo: now, calendar: calendar))
        XCTAssertFalse(ReviewPeriod.lastWeek.includes(cutoff.addingTimeInterval(-1), relativeTo: now, calendar: calendar))
    }

    /// A photo with no creation date can't be placed in any period, so it is left
    /// out rather than guessed at.
    func testPhotoWithoutADateIsNeverIncluded() {
        let now = date(2026, 9, 19)
        for period in ReviewPeriod.allCases {
            XCTAssertFalse(period.includes(nil, relativeTo: now, calendar: calendar))
        }
    }

    /// A camera with a wrong clock can stamp a photo slightly in the future. That
    /// is almost certainly a recent photo, so it stays in.
    func testFutureDatedPhotoIsIncluded() {
        let now = date(2026, 9, 19)
        XCTAssertTrue(ReviewPeriod.lastWeek.includes(date(2026, 9, 25), relativeTo: now, calendar: calendar))
    }

    func testLongerPeriodsContainShorterOnes() {
        let now = date(2026, 9, 19)
        for day in 0..<120 {
            let photo = calendar.date(byAdding: .day, value: -day, to: now)!
            if ReviewPeriod.lastWeek.includes(photo, relativeTo: now, calendar: calendar) {
                XCTAssertTrue(ReviewPeriod.lastMonth.includes(photo, relativeTo: now, calendar: calendar))
            }
            if ReviewPeriod.lastMonth.includes(photo, relativeTo: now, calendar: calendar) {
                XCTAssertTrue(ReviewPeriod.lastThreeMonths.includes(photo, relativeTo: now, calendar: calendar))
            }
        }
    }
}
