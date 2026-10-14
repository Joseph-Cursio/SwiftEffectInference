import SwiftParser
@testable import SwiftEffectInference
import SwiftSyntax
import Testing

/// What building `ConstructionFacts` costs where one name is declared in many files, on the shapes
/// `ConstructionNamesakeTests` pins the answers of.
///
/// SwiftProjectLint did not finish building the facts for the swift compiler's tree in an hour:
/// 23,000 files, each its own program, in one table, with `class A` declared 1,700 times and
/// `class B: A` a thousand. Every namesake is a candidate wherever its name is written, so an
/// answer grows with the namesakes, and a build that reads each answer is quadratic in them. What
/// these pin is that nothing costs more: no step passes every namesake for each candidate, or
/// every declaration for each lookup, or keeps what it found more than once.
///
/// **The ratio is the assertion**, as in `NondeterminismSourcesCostTests`: four times the files
/// against the same shape, best of three builds, so the machine's speed and a busy moment drop out.
@Suite("ConstructionFacts — namesake cost")
struct ConstructionNamesakeCostTests {

    /// The best of three timings of building the facts for `sources`.
    static func cost(of sources: [String]) -> Duration {
        let trees = sources.map { Parser.parse(source: $0) }
        let trials = (0..<3).map { _ in
            let start = ContinuousClock.now
            _ = ConstructionFacts.build(from: trees)
            return ContinuousClock.now - start
        }
        return trials.min() ?? .zero
    }

    /// Each `B`'s `A()` tries every `A` until one refutes, halfway along: quadratic, ~16 for four
    /// times the files. Passing every namesake to find each candidate's own index, or each lookup's
    /// superclasses, made it cubic: ~64.
    @Test("four times the subclass namesakes cost about sixteen times as much, not sixty-four", .timeLimit(.minutes(2)))
    func subclassNamesakesScale() {
        let short = Self.cost(of: ConstructionNamesakeTests.subclassNamesakes(copies: 250))
        let long = Self.cost(of: ConstructionNamesakeTests.subclassNamesakes(copies: 1000))
        let ratio = long / short
        #expect(
            ratio < 32,
            """
            building 4× the namesakes cost \(ratio)× as much. At ~64 something passes every namesake \
            for each candidate — see superclasses(of:) and superclassNames(ofQualified:).
            """
        )
    }

    /// `Self` in each class reads the class's subclasses: linear, ~4, when they are read from the
    /// table, and ~16 when each `Self` passed every declaration to find them.
    @Test("four times the classes building `Self` members cost about four times as much", .timeLimit(.minutes(2)))
    func selfInClassesScale() {
        let short = Self.cost(of: ConstructionNamesakeTests.selfInClasses(count: 400, distinct: true))
        let long = Self.cost(of: ConstructionNamesakeTests.selfInClasses(count: 1600, distinct: true))
        let ratio = long / short
        #expect(
            ratio < 8,
            """
            building 4× the classes cost \(ratio)× as much. At ~16 each `Self` passes every \
            declaration — see subtypes(of:).
            """
        )
    }

    /// Counted, not timed: `Self.Inner` through n namesakes of `S` used to hold each `Inner` n
    /// times, and a lookup over it repeated them again.
    @Test("no lookup holds a declaration twice, however many namesakes lead to it")
    func lookupsHoldEachDeclarationOnce() {
        let copies = 60
        let facts = ConstructionFacts.build(
            from: ConstructionNamesakeTests.selfNamesakes(copies: copies).map { Parser.parse(source: $0) }
        )
        let inners = facts.declarations.indices.filter { facts.declarations[$0].qualifiedName == "S.Inner" }
        #expect(inners.count == copies + 2)

        let lookups = facts.memo.settled.lookups
        let repeating = lookups.filter { Set($0.value).count != $0.value.count }
        #expect(repeating.isEmpty, "\(repeating.count) of \(lookups.count) lookups repeat a declaration")
        let throughSelf = lookups.filter { $0.key.components == ["Self", "Inner"] }
        #expect(!throughSelf.isEmpty)
        #expect(throughSelf.allSatisfy { $0.value == inners })
    }
}
