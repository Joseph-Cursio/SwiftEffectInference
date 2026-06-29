import SwiftParser
import SwiftSyntax
import Testing
@testable import SwiftEffectInference

/// Single-file smoke suite verifying the skeleton compiles and the public
/// types exist with the names the design doc commits to. Per-engine test
/// files (`EffectLatticeTests`, `EffectAnnotationParserTests`,
/// `CallSiteEffectInferrerTests`, `BodyEffectInferrerTests`,
/// `EffectSymbolTableTests`) land in migration step 3 alongside the lifted
/// implementations.
@Suite("SwiftEffectInference skeleton")
struct SkeletonSmokeTests {

    @Test
    func effectCasesExist() {
        let cases: [Effect] = [
            .pure,
            .observational,
            .idempotent,
            .externallyIdempotent(keyParameter: nil),
            .externallyIdempotent(keyParameter: "idempotencyKey"),
            .nonIdempotent
        ]
        // Hashable conformance — round-trip through Set without collapse.
        let unique = Set(cases)
        #expect(unique.count == cases.count)
    }

    @Test
    func effectAnnotationParserDefaultRecognitionMatchesSwiftIdempotency() {
        let parser = EffectAnnotationParser()
        let recognition = parser.recognition
        #expect(recognition.pure.contains("Pure"))
        #expect(recognition.idempotent.contains("Idempotent"))
        #expect(recognition.nonIdempotent.contains("NonIdempotent"))
        #expect(recognition.observational.contains("Observational"))
        #expect(recognition.externallyIdempotent.contains("ExternallyIdempotent"))
    }

    @Test
    func parsesPureFromDocCommentAnnotation() {
        let effect = effectOfFirstFunction(in: """
        /// Adds two numbers.
        /// @lint.effect pure
        func add(_ lhs: Int, _ rhs: Int) -> Int { lhs + rhs }
        """)
        #expect(effect == .pure)
    }

    @Test
    func parsesPureFromAttributeAnnotation() {
        let effect = effectOfFirstFunction(in: """
        @Pure
        func add(_ lhs: Int, _ rhs: Int) -> Int { lhs + rhs }
        """)
        #expect(effect == .pure)
    }

    /// Parses `source`, finds the first `func` declaration, and returns the
    /// `Effect` the default-recognition parser reads from it (or `nil`).
    private func effectOfFirstFunction(in source: String) -> Effect? {
        let tree = Parser.parse(source: source)
        let function = tree.statements.lazy
            .compactMap { $0.item.as(FunctionDeclSyntax.self) }
            .first
        guard let function else { return nil }
        return EffectAnnotationParser.parseEffect(declaration: function)
    }

    @Test
    func effectAnnotationParserAcceptsCustomRecognition() {
        let custom = EffectAnnotationParser.AttributeRecognition(
            idempotent: ["Idempotent", "MyTeamIdempotent"],
            nonIdempotent: ["NonIdempotent"],
            observational: ["Observational"],
            externallyIdempotent: ["ExternallyIdempotent"]
        )
        let parser = EffectAnnotationParser(recognition: custom)
        #expect(parser.recognition.idempotent.contains("MyTeamIdempotent"))
    }

    @Test
    func bodyInferenceCarriesEffectAndDepth() {
        let inference = BodyInference(effect: .nonIdempotent, depth: 3)
        #expect(inference.effect == .nonIdempotent)
        #expect(inference.depth == 3)
    }

    @Test
    func effectProvenanceCasesExist() {
        let cases: [EffectProvenance] = [
            .declared,
            .bodyInferred(depth: 2),
            .callSite(reason: "framework gate FluentKit.save")
        ]
        // Sendable + 3 cases — purely a compile-time / surface check.
        #expect(cases.count == 3)
    }

    @Test
    func effectSymbolTableLinks() {
        // Placeholder — `EffectSymbolTable.init()` is the only public API
        // until step 3 lifts the SPL implementation.
        let table = EffectSymbolTable()
        let _: EffectSymbolTable = table
    }

    @Test
    func inferrerNamespacesLink() {
        // Placeholder — the inferrers are empty namespaces until step 3.
        // The fact that these references compile is the assertion.
        let _: CallSiteEffectInferrer.Type = CallSiteEffectInferrer.self
        let _: BodyEffectInferrer.Type = BodyEffectInferrer.self
    }
}
