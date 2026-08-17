import SwiftParser
import SwiftSyntax
import Testing
@testable import SwiftEffectInference

/// A default argument is code the function runs, on exactly the calls that omit
/// it — so it is part of the purity question, and it was missing from the answer.
///
/// `bodyHasRefutingMarker` is handed `function.body`; a default value lives in
/// the signature. `func bridges(_ s: [S], now: Date = Date())` therefore read the
/// system clock on every defaulted call and was judged `.pure`, which is the
/// lattice-bottom mistake this type's soundness note forbids.
///
/// **Measured before the fix**, over SwiftInferProperties' `Sources/` at tree
/// `abbc0edb`: 15 of 2,456 non-refuted functions, fourteen `Date()` and one pair
/// reading `FileManager.default.currentDirectoryPath`, every one hand-checked.
/// The census that found it is `PurityAllowlistCensusMeasuredTests` in that repo,
/// where it was a finding the run was not looking for.
///
/// **The control is the point of this suite, not an afterthought.** The obvious
/// implementation — scan the signature for markers — refutes `func f(_ d: Date)`,
/// which is the *fixed* shape: a function that takes the clock's reading as an
/// argument is what every dependency-injection guide recommends, and it is
/// perfectly pure. A fix that punishes it is worse than the hole it closes.
/// `parameterTypeMentioningAMarkerStaysPure` is what separates the two.
///
/// **Both directions were watched failing rather than asserted.** With the new
/// refuter disabled, the five hole tests fail (6 issues) — so the fix is
/// load-bearing and not a restatement of a check that already existed. With the
/// refuter replaced by the naive whole-signature scan, both type controls fail —
/// so they discriminate, and are not two more tests that pass either way.
@Suite("Default arguments are part of the purity question")
struct DefaultArgumentPurityTests {

    private let inferrer = PurityInferrer()

    /// The first `func` in `source`.
    private func firstFunction(in source: String) throws -> FunctionDeclSyntax {
        let tree = Parser.parse(source: source)
        return try #require(
            tree.statements.lazy.compactMap { $0.item.as(FunctionDeclSyntax.self) }.first
        )
    }

    // MARK: - The hole

    @Test("a clock read in a default argument refutes purity")
    func clockInDefaultArgument() throws {
        let function = try firstFunction(in: """
        func stamp(_ id: Int, now: Date = Date()) -> String { "\\(id)@\\(now)" }
        """)
        #expect(inferrer.inferredEffect(for: function) == nil)
        #expect(inferrer.verdict(for: function) == .refuted)
    }

    @Test("a file-system read in a default argument refutes purity")
    func fileSystemInDefaultArgument() throws {
        let function = try firstFunction(in: """
        func resolve(
            _ target: String,
            relativeTo root: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ) -> URL {
            root.appendingPathComponent(target)
        }
        """)
        #expect(inferrer.inferredEffect(for: function) == nil)
    }

    @Test("randomness in a default argument refutes purity")
    func randomnessInDefaultArgument() throws {
        let function = try firstFunction(in: """
        func pick(_ values: [Int], index: Int = Int.random(in: 0..<10)) -> Int { values[index] }
        """)
        #expect(inferrer.inferredEffect(for: function) == nil)
    }

    /// Totality travels with the markers: a default that traps takes the call
    /// sites that omit it down, exactly as a trap in the body would.
    @Test("a trapping default argument refutes purity")
    func trappingDefaultArgument() throws {
        let function = try firstFunction(in: """
        func head(_ values: [Int], first: Int = defaults.first!) -> Int { values.first ?? first }
        """)
        #expect(inferrer.inferredEffect(for: function) == nil)
    }

    /// The throwing path must land on `.refuted`, not `.pureButPartial`. An impure
    /// default is an impurity, and `.pureButPartial` promises the function is
    /// deterministic wherever it is defined — which this one is not.
    @Test("an impure default refutes a throwing function outright, not to pureButPartial")
    func impureDefaultIsNotMerelyPartial() throws {
        let function = try firstFunction(in: """
        func parse(_ text: String, now: Date = Date()) throws -> Int {
            guard let value = Int(text) else { throw ParseError.bad }
            return value
        }
        """)
        #expect(inferrer.verdict(for: function) == .refuted)
    }

    // MARK: - The controls

    /// **The control that makes the fix a fix.** A marker in a parameter *type* is
    /// not an impurity — taking a `Date` is the opposite of reading one. A
    /// whole-signature token scan refutes this, and would refute the very shape
    /// the injection advice produces.
    @Test("a parameter TYPE mentioning a marker stays pure")
    func parameterTypeMentioningAMarkerStaysPure() throws {
        let function = try firstFunction(in: """
        func stamp(_ id: Int, now: Date) -> String { "\\(id)" }
        """)
        #expect(inferrer.inferredEffect(for: function) == .pure)
        #expect(inferrer.verdict(for: function) == .pure)
    }

    /// The same control on the return type, which a signature scan also reaches.
    @Test("a RETURN type mentioning a marker stays pure")
    func returnTypeMentioningAMarkerStaysPure() throws {
        let function = try firstFunction(in: """
        func shifted(_ base: Date, by seconds: Double) -> Date { base }
        """)
        #expect(inferrer.inferredEffect(for: function) == .pure)
    }

    /// An ordinary literal default is not an effect, and most defaults are these.
    /// Without this, "the refuter fires" is indistinguishable from "the refuter
    /// fires on everything with a default".
    @Test("an inert default argument leaves purity intact")
    func inertDefaultArgumentStaysPure() throws {
        let function = try firstFunction(in: """
        func pad(_ text: String, width: Int = 8, with filler: Character = " ") -> String { text }
        """)
        #expect(inferrer.inferredEffect(for: function) == .pure)
        #expect(inferrer.verdict(for: function) == .pure)
    }

    /// A defaulted, non-throwing, otherwise-transparent function is still
    /// `.pureButPartial` when it throws its own errors — the new refuter must not
    /// have swallowed that distinction.
    @Test("an inert default leaves pureButPartial reachable")
    func inertDefaultLeavesPartialReachable() throws {
        let function = try firstFunction(in: """
        func parse(_ text: String, radix: Int = 10) throws -> Int {
            guard let value = Int(text, radix: radix) else { throw ParseError.bad }
            return value
        }
        """)
        #expect(inferrer.verdict(for: function) == .pureButPartial)
    }
}
