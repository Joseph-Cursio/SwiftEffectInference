import SwiftParser
import SwiftSyntax
import Testing
@testable import SwiftEffectInference

/// The doc-comment scanning surface consumers reuse for their own annotation grammars.
///
/// The effect lattice is not the only thing written above a declaration — SwiftProjectLint's
/// `@lint.context` axis is another — and a sibling grammar that reads `decl.leadingTrivia`
/// directly sees nothing whenever the declaration carries an attribute or a modifier, because
/// SwiftSyntax parks the doc comment on *those* instead. Exposing the routing is what stops a
/// consumer re-deriving it and drifting.
@Suite("Doc-comment scanning")
struct DocCommentScanningTests {

    private static func function(_ source: String) throws -> FunctionDeclSyntax {
        let tree = Parser.parse(source: source)
        final class Finder: SyntaxVisitor {
            var found: FunctionDeclSyntax?
            override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
                if found == nil { found = node }
                return .skipChildren
            }
        }
        let finder = Finder(viewMode: .sourceAccurate)
        finder.walk(tree)
        return try #require(finder.found)
    }

    /// Every documentation line above `source`'s first function.
    private func lines(above source: String) throws -> [String] {
        let decl = try Self.function(source)
        return EffectAnnotationParser.documentationLines(
            in: EffectAnnotationParser.documentationTrivia(for: decl)
        )
    }

    @Test("a doc comment on a bare declaration is found")
    func bareDeclaration() throws {
        let found = try lines(above: """
        /// @lint.context replayable
        func handle() {}
        """)

        #expect(found.contains { $0.contains("@lint.context replayable") })
    }

    @Test("a doc comment above an attributed declaration is found")
    func attributedDeclaration() throws {
        // SwiftSyntax attaches this comment to `@MainActor`, not to `func`. A parser reading
        // `decl.leadingTrivia` would see nothing at all here.
        let found = try lines(above: """
        /// @lint.context once
        @MainActor
        func handle() {}
        """)

        #expect(found.contains { $0.contains("@lint.context once") })
    }

    @Test("a doc comment above a modified declaration is found")
    func modifiedDeclaration() throws {
        let found = try lines(above: """
        /// @lint.context retry_safe
        public func handle() {}
        """)

        #expect(found.contains { $0.contains("@lint.context retry_safe") })
    }

    @Test("a non-doc comment is not mistaken for documentation")
    func plainCommentIgnored() throws {
        let found = try lines(above: """
        // @lint.context once
        func handle() {}
        """)

        #expect(found.allSatisfy { !$0.contains("@lint.context") })
    }

    // MARK: - token(after:in:)

    @Test("the token after a marker is read up to whitespace, '(' or ':'")
    func tokenAfterMarker() {
        #expect(
            EffectAnnotationParser.token(after: "@lint.context", in: "@lint.context replayable")
                == "replayable"
        )
        #expect(
            EffectAnnotationParser.token(after: "@lint.context", in: " @lint.context   once  ")
                == "once"
        )
        #expect(
            EffectAnnotationParser.token(after: "@lint.context", in: "@lint.context strict_replayable")
                == "strict_replayable"
        )
        // A qualifier is not part of the tier name.
        #expect(
            EffectAnnotationParser.token(
                after: "@lint.effect",
                in: #"@lint.effect externally_idempotent(by: "key")"#
            ) == "externally_idempotent"
        )
    }

    @Test("an absent marker, or a marker with nothing after it, yields nil")
    func tokenAfterMarkerAbsent() {
        #expect(EffectAnnotationParser.token(after: "@lint.context", in: "no marker here") == nil)
        #expect(EffectAnnotationParser.token(after: "@lint.context", in: "@lint.context") == nil)
        #expect(EffectAnnotationParser.token(after: "@lint.context", in: "@lint.context   ") == nil)
    }
}
