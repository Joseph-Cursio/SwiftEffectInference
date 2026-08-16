import SwiftParser
import SwiftSyntax
import Testing
@testable import SwiftEffectInference

/// The classifier is consumed by two questions with different tolerances — a
/// lint rule that must not cry wolf, and a clock refuter that must not
/// contradict an honest annotation — so these pin both what it finds and what it
/// deliberately lets through.
@Suite("Nondeterminism sources: classification")
struct NondeterminismSourcesTests {

    /// Classifies every expression in a snippet and returns the first source, so
    /// a test can write the expression as it appears in real code rather than
    /// hand-building syntax nodes.
    private func firstSource(in source: String) -> NondeterminismSource? {
        final class Collector: SyntaxVisitor {
            var found: NondeterminismSource?
            override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
                if found == nil { found = NondeterminismSources.source(of: node) }
                return .visitChildren
            }
            override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
                if found == nil { found = NondeterminismSources.source(of: node) }
                return .visitChildren
            }
        }
        let collector = Collector(viewMode: .sourceAccurate)
        collector.walk(Parser.parse(source: source))
        return collector.found
    }

    @Test("clock sources are classified as clock", arguments: [
        ("let stamp = Date()", "Date()"),
        ("let stamp = Date.now", "Date.now"),
        ("let stamp = Date(timeIntervalSinceNow: 60)", "Date()"),
        ("let clock = ContinuousClock()", "ContinuousClock()"),
        ("let clock = SuspendingClock()", "SuspendingClock()"),
        ("let elapsed = CFAbsoluteTimeGetCurrent()", "CFAbsoluteTimeGetCurrent()"),
        ("let ticks = mach_absolute_time()", "mach_absolute_time()"),
        ("try await Task.sleep(for: .seconds(1))", "Task.sleep"),
        ("let stamp = DispatchTime.now()", "DispatchTime.now")
    ])
    func clockSources(source: String, marker: String) {
        let found = firstSource(in: source)
        #expect(found?.kind == .clock)
        #expect(found?.marker == marker)
    }

    @Test("randomness sources are classified as randomness", arguments: [
        ("let value = arc4random()", "arc4random()"),
        ("let value = drand48()", "drand48()"),
        ("let value = Int.random(in: 0..<10)", ".random(…)"),
        ("let value = values.randomElement()", ".randomElement(…)"),
        ("let value = values.shuffled()", ".shuffled(…)")
    ])
    func randomnessSources(source: String, marker: String) {
        let found = firstSource(in: source)
        #expect(found?.kind == .randomness)
        #expect(found?.marker == marker)
    }

    @Test("a fresh UUID is identity, not clock or randomness")
    func identitySource() {
        let found = firstSource(in: "let identifier = UUID()")
        #expect(found?.kind == .identity)
        #expect(found?.marker == "UUID()")
    }

    @Test("ambient environment reads are their own kind", arguments: [
        ("let locale = Locale.current", "Locale.current"),
        ("let zone = TimeZone.current", "TimeZone.current")
    ])
    func ambientEnvironmentSources(source: String, marker: String) {
        let found = firstSource(in: source)
        #expect(found?.kind == .ambientEnvironment)
        #expect(found?.marker == marker)
    }

    /// The injection seams. Each of these is the reproducible spelling of a
    /// source above, and the classifier has to tell them apart on the argument
    /// label alone — this is what a bare token scan cannot do, and the reason
    /// this type exists next to `PurityInferrer` rather than inside it.
    @Test("a supplied source of unpredictability is not a source", arguments: [
        "let value = Int.random(in: 0..<10, using: &generator)",
        "let value = values.shuffled(using: &generator)",
        "let value = values.randomElement(using: &generator)",
        "try await Task.sleep(for: .seconds(1), tolerance: nil, clock: clock)"
    ])
    func injectedForms_areNotSources(source: String) {
        #expect(firstSource(in: source) == nil)
    }

    @Test("a Date built from a fixed reference point is deterministic", arguments: [
        "let epoch = Date(timeIntervalSince1970: 0)",
        "let epoch = Date(timeIntervalSinceReferenceDate: 0)",
        "let later = Date(timeInterval: 60, since: epoch)"
    ])
    func fixedDates_areNotSources(source: String) {
        #expect(firstSource(in: source) == nil)
    }

    @Test("a UUID parsed from a string is determined by its input")
    func parsedUUID_isNotASource() {
        #expect(firstSource(in: #"let identifier = UUID(uuidString: "…")"#) == nil)
    }

    @Test("reading `now` on an injected clock is reproducible")
    func injectedClockRead_isNotASource() {
        #expect(firstSource(in: "let instant = clock.now") == nil)
    }

    @Test("a time type named in a signature is not an expression")
    func typeAnnotation_isNotASource() {
        #expect(firstSource(in: "func format(stamp: Date, clock: ContinuousClock) -> String { \"\" }") == nil)
    }

    @Test("`current` on a type this classifier does not know is not ambient")
    func unknownCurrent_isNotASource() {
        #expect(firstSource(in: "let step = workflow.current") == nil)
    }
}
