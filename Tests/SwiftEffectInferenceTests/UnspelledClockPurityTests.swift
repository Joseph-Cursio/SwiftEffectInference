import SwiftParser
import SwiftSyntax
import Testing
@testable import SwiftEffectInference

/// Clock and ambient reads that spell no marker. `main` caught each of these only when `Date` was
/// written somewhere else in the same body, so the token stood in for them. The cases here spell
/// no `Date` in their bodies, which is how they were judged `.pure` whenever the type came from
/// somewhere else: a parameter, a property, inference.
///
/// Found by the review of [#30](https://github.com/Joseph-Cursio/SwiftEffectInference/issues/30)'s
/// first fix, which stopped matching `Date` named as a type and turned every one of these
/// `.pure` in bodies that spelled it.
@Suite("A clock read that spells no marker is still a clock read")
struct UnspelledClockPurityTests {

    private func function(_ source: String) throws -> FunctionDeclSyntax {
        try #require(
            Parser.parse(source: source).statements.lazy.compactMap { $0.item.as(FunctionDeclSyntax.self) }.first
        )
    }

    private func verdict(_ source: String) throws -> PurityVerdict {
        PurityInferrer().verdict(for: try function(source))
    }

    // MARK: - A base-less `.now`

    /// Every library type with a static `now` reads a clock through it: `Date`, `DispatchTime`,
    /// `DispatchWallTime`, and `ContinuousClock.Instant` and `SuspendingClock.Instant`. The
    /// classifier matches `Date.now` only with its base written, and a contextual type supplies
    /// the base without spelling it.
    @Test("a base-less .now reads a clock", arguments: [
        "func f(_ base: Date) -> Bool { base < .now }",
        "func f(_ d: Date) -> TimeInterval { d.distance(to: .now) }",
        "func f(_ window: Range<Date>) -> Bool { window.contains(.now) }",
        "func f(_ deadline: DispatchTime) -> Bool { deadline < .now() }",
        "func f(_ start: ContinuousClock.Instant) -> Duration { start.duration(to: .now) }",
        "func f(_ s: Scheduler) -> Int { s.schedule(at: .now) }",
        "func f(_ base: Date) -> Bool { base < .now.addingTimeInterval(60) }",
        // A default spells it base-less too, and runs on every call that omits it.
        "func stamp(_ id: Int, now: Date = .now) -> String { \"\\(id)@\\(now)\" }"
    ])
    func baseLessNow(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    @Test("the witness is the base-less member")
    func baseLessNowWitness() throws {
        let refutation = PurityInferrer().refutation(for: try function("func f(_ base: Date) -> Bool { base < .now }"))
        #expect(refutation == .nondeterministicMarker(".now"))
    }

    /// `now` with a base is an injected clock's reading, and `now` alone is a name, most often the
    /// parameter that carries the injected instant.
    @Test("a now that is not a base-less member is not a clock read", arguments: [
        "func f(asOf now: Date) -> Date { now.addingTimeInterval(60) }",
        "func f(_ clock: Clock) -> Int { clock.now }",
        "func f(now: Int) -> Int { let later = now + 1; return later }",
        "func f(_ timing: Timing) -> Bool { timing == .later }"
    ])
    func nowThatIsNotBaseLess(source: String) throws {
        #expect(try verdict(source) == .pure, "\(source)")
    }
}
