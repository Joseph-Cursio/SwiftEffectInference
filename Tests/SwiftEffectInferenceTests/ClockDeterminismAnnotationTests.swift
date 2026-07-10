import SwiftParser
import SwiftSyntax
import Testing
@testable import SwiftEffectInference

@Suite
struct ClockDeterminismAnnotationTests {

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

    @Test
    func docCommentForm_marksDeclaration() throws {
        let function = try firstFunction(in: """
        /// @lint.determinism clock_deterministic
        func debounced<C: Clock>(clock: C) async -> Int { 1 }
        """)
        #expect(EffectAnnotationParser.isClockDeterministic(declaration: function))
    }

    @Test
    func attributeForm_marksDeclaration() throws {
        let function = try firstFunction(in: """
        @ClockDeterministic
        func debounced<C: Clock>(clock: C) async -> Int { 1 }
        """)
        #expect(EffectAnnotationParser.isClockDeterministic(declaration: function))
    }

    @Test
    func unmarkedAsyncFunction_isNotClockDeterministic() throws {
        let function = try firstFunction(in: """
        func fetch(_ id: Int) async -> Int { id }
        """)
        #expect(EffectAnnotationParser.isClockDeterministic(declaration: function) == false)
    }

    /// The two namespaces stay orthogonal: a determinism marker is not an
    /// effect tier, and an effect tier is not a determinism marker.
    @Test
    func determinismNamespace_doesNotLeakIntoEffectParsing() throws {
        let marked = try firstFunction(in: """
        /// @lint.determinism clock_deterministic
        func debounced<C: Clock>(clock: C) async -> Int { 1 }
        """)
        #expect(EffectAnnotationParser.parseEffect(declaration: marked) == nil)

        let tiered = try firstFunction(in: """
        /// @lint.effect pure
        func addOne(_ value: Int) -> Int { value + 1 }
        """)
        #expect(EffectAnnotationParser.isClockDeterministic(declaration: tiered) == false)
    }
}
