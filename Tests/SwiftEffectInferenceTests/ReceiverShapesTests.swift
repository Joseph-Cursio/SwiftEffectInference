import SwiftParser
import SwiftSyntax
import Testing
@testable import SwiftEffectInference

/// Characterization suite for `ReceiverShapes.resolve`.
///
/// Pins receiver-type resolution across the literal/constructor surface
/// shapes and all four stored-property-bearing declaration kinds (class,
/// struct, actor, extension). Written to guard the extraction of the shared
/// `literalOrConstructorShape` and `memberBlockMembers` helpers.
@Suite("ReceiverShapes resolution")
struct ReceiverShapesTests {

    /// Parses `source` and returns its first `FunctionCallExprSyntax`.
    private static func firstCall(in source: String) -> FunctionCallExprSyntax {
        let tree = Parser.parse(source: source)
        final class Finder: SyntaxVisitor {
            var found: FunctionCallExprSyntax?
            override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
                if found == nil { found = node }
                return .visitChildren
            }
        }
        let finder = Finder(viewMode: .sourceAccurate)
        finder.walk(tree)
        guard let call = finder.found else {
            fatalError("no FunctionCallExprSyntax found in: \(source)")
        }
        return call
    }

    private static func resolve(_ source: String) -> ResolvedReceiverType {
        ReceiverShapes.resolve(receiverOf: firstCall(in: source))
    }

    // MARK: - Literal & constructor surface shapes (literalOrConstructorShape)

    @Test("array literal receiver resolves to stdlib Array")
    func arrayLiteral() {
        #expect(Self.resolve("[1, 2].append(3)") == .stdlibCollection("Array"))
    }

    @Test("string literal receiver resolves to stdlib String")
    func stringLiteral() {
        #expect(Self.resolve("\"hi\".append(\"x\")") == .stdlibCollection("String"))
    }

    @Test("dictionary literal receiver resolves to stdlib Dictionary")
    func dictionaryLiteral() {
        #expect(Self.resolve("[:].merge(other)") == .stdlibCollection("Dictionary"))
    }

    @Test("constructor receiver resolves to named type")
    func constructorCall() {
        #expect(Self.resolve("Queue().enqueue(x)") == .named("Queue"))
    }

    // MARK: - Stored-property lookup across all four decl kinds (memberBlockMembers)

    @Test("stored property in class resolves via annotation")
    func classStoredProperty() {
        let source = """
        class C {
            let items: [Int]
            func go() { items.append(1) }
        }
        """
        #expect(Self.resolve(source) == .stdlibCollection("Array"))
    }

    @Test("stored property in struct resolves via annotation")
    func structStoredProperty() {
        let source = """
        struct S {
            var name: String
            func go() { name.append("x") }
        }
        """
        #expect(Self.resolve(source) == .stdlibCollection("String"))
    }

    @Test("stored property in actor resolves via annotation")
    func actorStoredProperty() {
        let source = """
        actor A {
            let queue: Queue
            func go() { queue.enqueue(1) }
        }
        """
        #expect(Self.resolve(source) == .named("Queue"))
    }

    @Test("property in extension resolves via annotation")
    func extensionStoredProperty() {
        let source = """
        extension E {
            var values: [String]
            func go() { values.append("x") }
        }
        """
        // The resolver reads the type annotation syntactically; it does not
        // distinguish stored from computed, so an annotated member in an
        // extension resolves the same as one in a class/struct/actor.
        #expect(Self.resolve(source) == .stdlibCollection("Array"))
    }

    @Test("self.<name> member access resolves to stored property type")
    func selfMemberAccess() {
        let source = """
        struct S {
            let items: [Int]
            func go() { self.items.append(1) }
        }
        """
        #expect(Self.resolve(source) == .stdlibCollection("Array"))
    }

    // MARK: - Local binding via initializer shape (shared helper)

    @Test("untyped local binding resolves via initializer literal shape")
    func localBindingInitializerShape() {
        let source = """
        func go() {
            let xs = [1, 2]
            xs.append(3)
        }
        """
        #expect(Self.resolve(source) == .stdlibCollection("Array"))
    }

    @Test("receiverless call is unresolved")
    func receiverless() {
        #expect(Self.resolve("doThing()") == .unresolved)
    }
}
