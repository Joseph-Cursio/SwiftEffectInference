import SwiftParser
import SwiftSyntax
import Testing
@testable import SwiftEffectInference

/// Reads of the user's calendar, locale and time zone that the classifier does not know. Each
/// answers differently on a machine set to another time zone or locale, so none is a function of
/// its inputs. `main` caught them only when `Date` was written somewhere else in the same body.
///
/// Found by the review of [#30](https://github.com/Joseph-Cursio/SwiftEffectInference/issues/30)'s
/// first fix, which stopped matching `Date` named as a type and turned these `.pure` in bodies
/// that spelled it.
@Suite("Ambient settings are not inputs")
struct AmbientSettingsPurityTests {

    private func function(_ source: String) throws -> FunctionDeclSyntax {
        try #require(
            Parser.parse(source: source).statements.lazy.compactMap { $0.item.as(FunctionDeclSyntax.self) }.first
        )
    }

    private func verdict(_ source: String) throws -> PurityVerdict {
        PurityInferrer().verdict(for: try function(source))
    }

    private func refutation(_ source: String) throws -> PurityRefutation? {
        PurityInferrer().refutation(for: try function(source))
    }

    // MARK: - The ambient calendar

    /// `Calendar.current` carries the process's time zone and the locale's calendar, so the year,
    /// the start of a day and the first weekday all move with the machine's settings.
    @Test("Calendar.current reads the ambient settings", arguments: [
        "func year(_ d: Date) -> Int { Calendar.current.component(.year, from: d) }",
        "func day(_ d: Date) -> Date { Calendar.current.startOfDay(for: d) }",
        "func days(_ ds: [Date]) -> [Int] { ds.map { Calendar.current.component(.day, from: $0) } }"
    ])
    func calendarCurrent(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    @Test("the witness is Calendar.current")
    func calendarCurrentWitness() throws {
        let source = "func year(_ d: Date) -> Int { Calendar.current.component(.year, from: d) }"
        #expect(try refutation(source) == .nondeterministicMarker("Calendar.current"))
    }

    /// A calendar handed in is the injection seam, and `current` on anything but `Calendar` is
    /// some other type's.
    @Test("a calendar handed in, or another type's current, is not ambient", arguments: [
        "func year(_ d: Date, in calendar: Calendar) -> Int { calendar.component(.year, from: d) }",
        "func first(_ calendar: Calendar) -> Int { calendar.firstWeekday }",
        "func level(_ config: Configuration) -> Int { config.current.level }"
    ])
    func calendarHandedIn(source: String) throws {
        #expect(try verdict(source) == .pure, "\(source)")
    }

    // MARK: - `autoupdatingCurrent`

    /// `Locale.autoupdatingCurrent`, `TimeZone.autoupdatingCurrent` and
    /// `Calendar.autoupdatingCurrent` follow the user's settings as they change. They are also
    /// the default of every Foundation format style, so a default argument spells them base-less.
    @Test("autoupdatingCurrent reads the ambient settings", arguments: [
        "func id() -> String { Locale.autoupdatingCurrent.identifier }",
        "func zone() -> String { TimeZone.autoupdatingCurrent.identifier }",
        "func year(_ d: Date) -> Int { Calendar.autoupdatingCurrent.component(.year, from: d) }",
        "func label(_ n: Int, locale: Locale = .autoupdatingCurrent) -> String { String(n) }"
    ])
    func autoupdatingCurrent(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    @Test("the witness is autoupdatingCurrent")
    func autoupdatingCurrentWitness() throws {
        let source = "func id() -> String { Locale.autoupdatingCurrent.identifier }"
        #expect(try refutation(source) == .nondeterministicMarker("autoupdatingCurrent"))
    }
}
