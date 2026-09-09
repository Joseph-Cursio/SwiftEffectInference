import SwiftParser
@testable import SwiftEffectInference
import SwiftSyntax
import Testing

/// `inferredEffect(for:)` stopped delegating to `verdict(for:)` for performance
/// ([#1](https://github.com/Joseph-Cursio/SwiftEffectInference/issues/1)) — the
/// whole-domain question can reject `throws` on the signature, while `verdict`
/// must walk a throwing body to tell `.pureButPartial` from `.refuted`.
///
/// **Two implementations of one answer is exactly the shape that drifts**, so
/// this pins the equivalence the doc claims: for every function,
/// `inferredEffect(for:) == .pure` **iff** `verdict(for:) == .pure`. If someone
/// later teaches one path a refuter and forgets the other, this fails rather
/// than the two quietly disagreeing in a consumer.
@Suite("PurityInferrer — the two entry points agree, by construction and after")
struct PurityEntryPointEquivalenceTests {

    /// Deliberately spans every branch both paths can take: body-less, `async`,
    /// `throws` (both own-error and foreign-error), refuting markers, partiality,
    /// and the plainly pure control. A subset that missed the throwing rows would
    /// pass while testing nothing — those are the rows the split created.
    static let subjects: [(String, String)] = [
        ("plainly pure", "func f(_ x: Int) -> Int { x * 2 }"),
        ("body-less requirement", "func f(_ x: Int) -> Int"),
        ("async", "func f(_ x: Int) async -> Int { x }"),
        ("throws, own errors only", """
        func f(_ x: Int) throws -> Int {
            guard x > 0 else { throw MyError.bad }
            return x
        }
        """),
        ("throws, foreign errors", """
        func f(_ path: String) throws -> String {
            try String(contentsOfFile: path, encoding: .utf8)
        }
        """),
        ("async AND throws", "func f(_ x: Int) async throws -> Int { x }"),
        ("nondeterminism marker", "func f() -> Int { Int.random(in: 0 ..< 10) }"),
        ("clock reader", "func f() -> Date { Date() }"),
        ("partial — force unwrap", "func f(_ x: Int?) -> Int { x! }"),
        ("partial — division", "func f(_ x: Int, _ y: Int) -> Int { x / y }"),
        ("throws + refuting marker", """
        func f() throws -> Int {
            throw MyError.bad
        }
        """)
    ]

    @Test("inferredEffect == .pure iff verdict == .pure", arguments: subjects)
    func entryPointsAgree(label: String, source: String) throws {
        let function = try #require(
            Parser.parse(source: source)
                .statements
                .compactMap { $0.item.as(FunctionDeclSyntax.self) }
                .first,
            "could not parse a function from: \(label)"
        )
        let inferrer = PurityInferrer()
        let viaInferred = inferrer.inferredEffect(for: function) == .pure
        let viaVerdict = inferrer.verdict(for: function) == .pure
        #expect(viaInferred == viaVerdict, "entry points disagree on: \(label)")
        // `isPure(_:)` is documented as the boolean form of `inferredEffect`, so
        // it has to move with it — it is the third copy of the same answer.
        #expect(inferrer.isPure(function) == viaInferred, "isPure disagrees on: \(label)")
    }

    /// The equivalence above would also hold if BOTH paths were wrong in the same
    /// way, so one row is asserted absolutely rather than relatively.
    @Test("A throwing function is refuted on the whole-domain question")
    func throwsIsRefutedOutright() throws {
        let source = """
        func parse(_ text: String) throws -> Int {
            guard let value = Int(text) else { throw MyError.bad }
            return value
        }
        """
        let function = try #require(
            Parser.parse(source: source).statements
                .compactMap { $0.item.as(FunctionDeclSyntax.self) }.first
        )
        let inferrer = PurityInferrer()
        #expect(inferrer.inferredEffect(for: function) == nil)
        // …and the whole point of keeping `verdict` separate: it says something
        // the whole-domain answer cannot, and still walks the body to do so.
        #expect(inferrer.verdict(for: function) == .pureButPartial)
    }

    /// Publishing the witness added a **third** and **fourth** copy of the same
    /// answer, so the suite that exists to stop this drifting has to cover them.
    ///
    /// Both verdict-shaped methods are now *defined* as "the witness returned
    /// nothing", which makes drift impossible by construction rather than by
    /// discipline — and that is exactly the claim worth pinning, because the next
    /// person to add a refuter can restore the duplication in one edit.
    ///
    /// **The two rows are deliberately different predicates.** A `.pureButPartial`
    /// function is not refuted at all — it has been narrowed — so the verdict-shaped
    /// witness returns `nil` for it, while the whole-domain one returns
    /// `.declaredThrows`. Asserting the same equality for both would have failed,
    /// which is how this test says the asymmetry is intended.
    @Test("verdict and witness cannot disagree", arguments: subjects)
    func witnessAgreesWithVerdict(label: String, source: String) throws {
        let function = try #require(
            Parser.parse(source: source)
                .statements
                .compactMap { $0.item.as(FunctionDeclSyntax.self) }
                .first,
            "could not parse a function from: \(label)"
        )
        let inferrer = PurityInferrer()
        #expect(
            (inferrer.refutation(for: function) == nil) == (inferrer.verdict(for: function) != .refuted),
            "witness and verdict disagree on: \(label)"
        )
        #expect(
            (inferrer.wholeDomainRefutation(for: function) == nil)
                == (inferrer.inferredEffect(for: function) == .pure),
            "whole-domain witness and inferredEffect disagree on: \(label)"
        )
    }

    /// `.declaredThrows` is the one case the verdict-shaped question can never
    /// produce, and it is the entire difference between the two questions. A
    /// refuter accidentally taught to `refutation(for:)` instead of to
    /// `wholeDomainRefutation(for:)` would collapse them, and nothing else here
    /// would notice.
    @Test("only the whole-domain question refutes on `throws`", arguments: subjects)
    func onlyTheWholeDomainQuestionRefutesOnThrows(label: String, source: String) throws {
        let function = try #require(
            Parser.parse(source: source)
                .statements
                .compactMap { $0.item.as(FunctionDeclSyntax.self) }
                .first
        )
        #expect(
            PurityInferrer().refutation(for: function) != .declaredThrows,
            "`throws` is a narrowing, not a refutation, on: \(label)"
        )
    }
}
