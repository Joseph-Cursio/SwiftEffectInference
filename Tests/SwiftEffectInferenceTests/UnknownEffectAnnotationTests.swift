import SwiftParser
import SwiftSyntax
import Testing
@testable import SwiftEffectInference

/// `@EffectUnknown` — the author saying *"I cannot determine the effect here"*.
///
/// The distinction these tests exist to protect is between **the author declined
/// to claim a tier** and **the author said nothing at all**. Before
/// `declaresUnknownEffect`, `parseEffect` returned `nil` for both, and for a
/// misspelled tier as well, so the marker documented intent that no tool could
/// read.
///
/// It is deliberately not an `Effect` case and deliberately not projected onto
/// one — see the predicate's own doc for why `unknown` differs from
/// `transactional_idempotent`, which *is* projected.
@Suite("Unknown-effect annotation")
struct UnknownEffectAnnotationTests {

    private func firstFunction(in source: String) throws -> FunctionDeclSyntax {
        final class Finder: SyntaxVisitor {
            var found: FunctionDeclSyntax?
            override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
                if found == nil { found = node }
                return .skipChildren
            }
        }
        let finder = Finder(viewMode: .sourceAccurate)
        finder.walk(Parser.parse(source: source))
        return try #require(finder.found)
    }

    @Test("the doc-comment form marks the declaration")
    func docCommentFormMarksDeclaration() throws {
        let function = try firstFunction(in: """
        /// @lint.effect unknown
        func syncFromVendor() -> Int { 1 }
        """)
        #expect(EffectAnnotationParser.declaresUnknownEffect(declaration: function))
    }

    @Test("the attribute form marks the declaration")
    func attributeFormMarksDeclaration() throws {
        let function = try firstFunction(in: """
        @EffectUnknown
        func syncFromVendor() -> Int { 1 }
        """)
        #expect(EffectAnnotationParser.declaresUnknownEffect(declaration: function))
    }

    @Test("an unannotated declaration is not marked")
    func unannotatedIsNotMarked() throws {
        let function = try firstFunction(in: "func syncFromVendor() -> Int { 1 }")
        #expect(EffectAnnotationParser.declaresUnknownEffect(declaration: function) == false)
    }

    /// The point of the marker, stated as a test: `unknown` must not be confused
    /// with a claim, and `@NonIdempotent` is the claim authors reached for when
    /// they had no way to say *"I do not know"*. It is strictly stronger.
    @Test("a real tier is not read as unknown, and unknown is not read as a tier")
    func unknownAndTiersAreDistinct() throws {
        let nonIdempotent = try firstFunction(in: """
        /// @lint.effect non_idempotent
        func sendEmail() { }
        """)
        #expect(EffectAnnotationParser.declaresUnknownEffect(declaration: nonIdempotent) == false)
        #expect(EffectAnnotationParser().parseEffect(declaration: nonIdempotent) == .nonIdempotent)

        let unknown = try firstFunction(in: """
        /// @lint.effect unknown
        func syncFromVendor() { }
        """)
        #expect(EffectAnnotationParser.declaresUnknownEffect(declaration: unknown))
        // Still `nil`: `unknown` is not a tier in this module's linear `Effect`,
        // and manufacturing one would claim what the author declined to claim.
        #expect(EffectAnnotationParser().parseEffect(declaration: unknown) == nil)
    }

    /// The gap that motivated the marker, pinned from the consumer's side: a
    /// misspelling and an explicit `unknown` both yield `nil` from `parseEffect`,
    /// so `parseEffect` alone cannot tell them apart — and the predicate can.
    @Test("a misspelled tier is distinguishable from an explicit unknown")
    func misspelledTierIsNotUnknown() throws {
        let misspelled = try firstFunction(in: """
        /// @lint.effect unknwon
        func syncFromVendor() { }
        """)
        #expect(EffectAnnotationParser().parseEffect(declaration: misspelled) == nil)
        #expect(EffectAnnotationParser.declaresUnknownEffect(declaration: misspelled) == false)
    }

    @Test("a near-miss attribute name does not mark the declaration")
    func nearMissAttributeIsNotMarked() throws {
        let function = try firstFunction(in: """
        @EffectUnknwon
        func syncFromVendor() -> Int { 1 }
        """)
        #expect(EffectAnnotationParser.declaresUnknownEffect(declaration: function) == false)
    }

    @Test("variable bindings carry the marker too")
    func variableBindingFormIsRead() throws {
        final class Finder: SyntaxVisitor {
            var found: VariableDeclSyntax?
            override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
                if found == nil { found = node }
                return .skipChildren
            }
        }
        let finder = Finder(viewMode: .sourceAccurate)
        finder.walk(Parser.parse(source: """
        /// @lint.effect unknown
        let handler: () -> Void = { }
        """))
        let binding = try #require(finder.found)
        #expect(EffectAnnotationParser().declaresUnknownEffect(declaration: binding))
    }
}
