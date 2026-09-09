import SwiftParser
@testable import SwiftEffectInference
import SwiftSyntax
import Testing

/// The witness, case by case.
///
/// `PurityVerdict` said *refuted* and nothing else, so a consumer could gate on purity and could not
/// report on it. The rules downstream that inventory property-test candidates are purity-gated, which
/// means every run computes the list of things blocking a property test and throws it away; and
/// SwiftProjectLint's `PackagePurityJoin` infers a witness from the `throws` clause because that was
/// the only refutation reason visible from outside.
///
/// So these tests are about the **payload**, not the pass/fail. A refutation that fires with the
/// wrong name in it is worse than no refutation: the consumer prints it.
@Suite("Purity refutation — the witness names the thing")
struct PurityRefutationTests {

    private let inferrer = PurityInferrer()

    private func function(in source: String) throws -> FunctionDeclSyntax {
        try #require(
            Parser.parse(source: source).statements
                .compactMap { $0.item.as(FunctionDeclSyntax.self) }.first,
            "no function in: \(source)"
        )
    }

    private func closure(in source: String) throws -> ClosureExprSyntax {
        final class Finder: SyntaxVisitor {
            var found: ClosureExprSyntax?
            override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
                if found == nil { found = node }
                return .skipChildren
            }
        }
        let finder = Finder(viewMode: .sourceAccurate)
        finder.walk(Parser.parse(source: source))
        return try #require(finder.found)
    }

    private func accessor(in source: String) throws -> AccessorBlockSyntax {
        final class Finder: SyntaxVisitor {
            var found: AccessorBlockSyntax?
            override func visit(_ node: AccessorBlockSyntax) -> SyntaxVisitorContinueKind {
                if found == nil { found = node }
                return .skipChildren
            }
        }
        let finder = Finder(viewMode: .sourceAccurate)
        finder.walk(Parser.parse(source: source))
        return try #require(finder.found)
    }

    // MARK: - Shape refutations

    @Test("a body-less requirement is refuted for want of anything to read")
    func bodyLessRequirement() throws {
        #expect(try inferrer.refutation(for: function(in: "func f(_ x: Int) -> Int")) == .noBody)
    }

    @Test("async names itself")
    func declaredAsync() throws {
        #expect(try inferrer.refutation(for: function(in: "func f() async -> Int { 1 }")) == .declaredAsync)
    }

    // MARK: - Markers

    @Test("a side-effect marker carries the token as written")
    func sideEffectMarkerNamesTheToken() throws {
        let refutation = try inferrer.refutation(for: function(in: """
        func root() -> String { FileManager.default.currentDirectoryPath }
        """))
        #expect(refutation == .sideEffectMarker("FileManager"))
    }

    @Test("a nondeterminism marker carries the token as written")
    func nondeterministicMarkerNamesTheToken() throws {
        let refutation = try inferrer.refutation(for: function(in: "func stamp() -> Date { Date() }"))
        #expect(refutation == .nondeterministicMarker("Date"))
    }

    /// The two marker kinds are separate cases because they carry different confidence, and the
    /// classifier is the reason: it reads argument labels and the token scan does not.
    @Test("a source only the classifier knows arrives as the classification, not as a token")
    func classifierSourceCarriesItsKind() throws {
        let refutation = try inferrer.refutation(for: function(in: """
        func ticks() -> UInt64 { mach_absolute_time() }
        """))
        guard case .nondeterminismSource(let source) = try #require(refutation) else {
            Issue.record("expected a classifier source, got \(String(describing: refutation))")
            return
        }
        #expect(source.kind == .monotonicClock)
        #expect(source.marker.contains("mach_absolute_time"))
    }

    @Test("a file read names the callee with its label")
    func fileReadNamesTheCallee() throws {
        let refutation = try inferrer.refutation(for: function(in: """
        func text(at url: URL) -> String {
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        """))
        #expect(refutation == .fileRead("String(contentsOf:)"))
    }

    // MARK: - Partiality

    @Test("each trap is named separately", arguments: [
        ("func f(_ x: Int?) -> Int { x! }", PurityRefutation.Partiality.forceUnwrap),
        ("func f() -> Int { try! parse() }", .forcedTry),
        ("func f(_ x: Any) -> Int { x as! Int }", .forcedCast),
        ("func f() -> Int { fatalError(\"unreachable\") }", .trap("fatalError")),
        ("func f(_ x: Int) -> Int { precondition(x > 0); return x }", .trap("precondition"))
    ])
    func partialityNamesTheTrap(source: String, expected: PurityRefutation.Partiality) throws {
        #expect(try inferrer.refutation(for: function(in: source)) == .partiality(expected))
    }

    // MARK: - Default arguments

    /// The recursive case, and the reason it is recursive: *`now` defaults to something that reads
    /// the clock* is the diagnostic. *`now` has a bad default* is not.
    @Test("a refuting default names the parameter AND the cause")
    func defaultArgumentCarriesBoth() throws {
        let refutation = try inferrer.refutation(for: function(in: """
        func bridges(_ items: [Item], now: Date = Date()) -> [Bridge] { [] }
        """))
        #expect(refutation == .refutingDefaultArgument(parameter: "now", cause: .nondeterministicMarker("Date")))
    }

    @Test("a trapping default is reported as one")
    func trappingDefaultIsPartiality() throws {
        let refutation = try inferrer.refutation(for: function(in: """
        func head(_ xs: [Int], first: Int = [1].first!) -> Int { first }
        """))
        #expect(refutation == .refutingDefaultArgument(parameter: "first", cause: .partiality(.forceUnwrap)))
    }

    // MARK: - Throwing, which is the case that is NOT a refutation

    /// `.pureButPartial` is a narrowing, not a refusal, so there is no witness for it — and this is
    /// the one asymmetry a consumer has to know about.
    @Test("a function that raises only its own errors is not refuted at all")
    func ownErrorsProduceNoWitness() throws {
        let subject = try function(in: """
        func parse(_ text: String) throws -> Int {
            guard let value = Int(text) else { throw MyError.bad }
            return value
        }
        """)
        #expect(inferrer.refutation(for: subject) == nil)
        #expect(inferrer.verdict(for: subject) == .pureButPartial)
        // …and the whole-domain question, which is a different question, does have one.
        #expect(inferrer.wholeDomainRefutation(for: subject) == .declaredThrows)
    }

    @Test("a throw propagated out of a callee is refuted, and says so")
    func foreignErrorsArePropagatedTry() throws {
        let refutation = try inferrer.refutation(for: function(in: """
        func run(_ command: Command) throws -> Int {
            try command.execute()
        }
        """))
        #expect(refutation == .propagatedTry)
    }

    // MARK: - Closures

    @Test("a captured write names the root it escapes into")
    func capturedWriteNamesTheRoot() throws {
        let refutation = try inferrer.refutation(for: closure(in: """
        let _ = items.forEach { total += $0.size }
        """))
        #expect(refutation == .mutatesCapturedState("total"))
    }

    @Test("a write through a member names the base, because that is what escapes")
    func capturedMemberWriteNamesTheBase() throws {
        let refutation = try inferrer.refutation(for: closure(in: """
        let _ = items.forEach { self.cache[$0.key] = $0 }
        """))
        #expect(refutation == .mutatesCapturedState("self"))
    }

    /// A closure has no `.pureButPartial`: nothing downstream narrows a law's domain to an anonymous
    /// callee's success set, so `throws` refutes here where it does not on a function.
    @Test("a throwing closure is refuted outright")
    func throwingClosureIsRefuted() throws {
        let refutation = try inferrer.refutation(for: closure(in: """
        let f = { (x: Int) throws -> Int in x }
        """))
        #expect(refutation == .declaredThrows)
    }

    // MARK: - Accessors

    @Test("a setter names the specifier that disqualified the property")
    func setterNamesItsSpecifier() throws {
        let refutation = try inferrer.refutation(for: accessor(in: """
        struct Box {
            var value: Int {
                get { stored }
                set { stored = newValue }
            }
        }
        """))
        #expect(refutation == .notAGetter("set"))
    }

    @Test("an observed stored property is a statement, not a bug")
    func didSetNamesItsSpecifier() throws {
        let refutation = try inferrer.refutation(for: accessor(in: """
        struct Box {
            var value: Int = 0 {
                didSet { print(value) }
            }
        }
        """))
        #expect(refutation == .notAGetter("didSet"))
    }

    @Test("a protocol's get-only requirement has no body to read")
    func getOnlyRequirementHasNoBody() throws {
        let refutation = try inferrer.refutation(for: accessor(in: """
        protocol Sized { var count: Int { get } }
        """))
        #expect(refutation == .noBody)
    }

    // MARK: - Order

    /// Every entry point routes through one `bodyRefutation`, so which witness a consumer sees must
    /// not depend on which door it came in by. Markers before totality, everywhere.
    @Test("a body with both a marker and a trap reports the marker")
    func markersOutrankTraps() throws {
        let source = """
        func f(_ x: Int?) -> Int {
            print(x!)
            return x!
        }
        """
        #expect(try inferrer.refutation(for: function(in: source)) == .sideEffectMarker("print"))
        // The same body, reached through the accessor door, agrees.
        let asGetter = try accessor(in: """
        struct Box {
            var value: Int { print(x!); return x! }
        }
        """)
        #expect(inferrer.refutation(for: asGetter) == .sideEffectMarker("print"))
    }

    /// Each walker keeps the **first** thing it saw, and nothing short-circuits, so a walker that
    /// kept the last one instead would report a different witness for the same function without
    /// changing a single purity answer. Two different traps in one body is the only arrangement
    /// where the two rules disagree.
    @Test("the first trap wins, not the last")
    func firstTrapWins() throws {
        let refutation = try inferrer.refutation(for: function(in: """
        func f(_ x: Int?) -> Int {
            precondition(x != nil)
            return x!
        }
        """))
        #expect(refutation == .partiality(.trap("precondition")))
    }

    // MARK: - Rendering

    /// The consumers are writing messages for a reader who has to decide what to do about the
    /// refusal, so the rendering names the thing rather than classifying it.
    @Test("the description names the thing", arguments: [
        (PurityRefutation.sideEffectMarker("FileManager"), "FileManager"),
        (.nondeterministicMarker("Date"), "Date"),
        (.fileRead("String(contentsOf:)"), "String(contentsOf:)"),
        (.partiality(.trap("fatalError")), "fatalError"),
        (.mutatesCapturedState("total"), "total"),
        (.notAGetter("didSet"), "didSet")
    ])
    func descriptionNamesTheThing(refutation: PurityRefutation, needle: String) {
        #expect(refutation.description.contains(needle), "\(refutation)")
    }

    /// The nested case has to render both halves or it loses the half a reader acts on.
    @Test("a defaulted parameter renders the parameter and the cause")
    func nestedDescriptionRendersBoth() {
        let rendered = PurityRefutation
            .refutingDefaultArgument(parameter: "now", cause: .nondeterministicMarker("Date"))
            .description
        #expect(rendered.contains("now"))
        #expect(rendered.contains("Date"))
    }
}
