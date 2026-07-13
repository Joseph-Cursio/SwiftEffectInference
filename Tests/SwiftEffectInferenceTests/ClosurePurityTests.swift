import SwiftParser
import SwiftSyntax
import Testing
@testable import SwiftEffectInference

/// Purity, asked of a closure literal.
///
/// A great deal of the pure logic in real Swift has no name. A `filter` predicate or a
/// `sorted(by:)` comparator written inline is a pure function in everything but syntax, and being
/// anonymous is the only thing standing between it and a property test.
///
/// The subtle case is **captures**. A closure that reads a captured `var` is still pure *as a
/// function*: lift the body into a named function and the capture simply becomes a parameter. What
/// the caller does with its own state is the caller's business. What no extraction can rescue is a
/// closure that **writes** to what it captured — its whole job is the side effect.
@Suite("Closure purity")
struct ClosurePurityTests {

    /// The first closure literal in `source`.
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

    private func isPure(_ source: String) throws -> Bool {
        PurityInferrer().isPure(try closure(in: source))
    }

    // MARK: - Pure

    @Test("a comparator over its own parameters is pure")
    func comparatorIsPure() throws {
        #expect(try isPure("""
        let sorted = items.sorted { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
            return lhs.name < rhs.name
        }
        """))
    }

    @Test("a predicate that READS a capture is pure — the capture becomes a parameter")
    func readingACaptureIsPure() throws {
        // `currentPath` is a `var` on the enclosing type. Irrelevant: lift the body into
        // `isChild(_ path: String, of parent: String)` and the capture is just an argument.
        #expect(try isPure("""
        let children = files.filter { file in
            file.path.hasPrefix(currentPath)
        }
        """))
    }

    @Test("a closure using $0 is pure")
    func anonymousArgumentIsPure() throws {
        #expect(try isPure("let evens = numbers.filter { $0 % 2 == 0 }"))
    }

    // MARK: - Refuted

    @Test("a closure that WRITES to a capture is not pure — no extraction rescues it")
    func writingToACaptureIsImpure() throws {
        #expect(try isPure("""
        items.forEach { item in
            total += item.amount
        }
        """) == false)
    }

    @Test("a closure that writes through a captured object is not pure")
    func writingThroughACaptureIsImpure() throws {
        #expect(try isPure("""
        items.forEach { item in
            cache.count = item.amount
        }
        """) == false)
    }

    @Test("assigning to its OWN local is fine — that is not state")
    func writingToALocalIsPure() throws {
        #expect(try isPure("""
        let mapped = items.map { item in
            var name = item.name
            name += "!"
            return name
        }
        """))
    }

    @Test("a closure doing I/O is not pure")
    func sideEffectIsImpure() throws {
        #expect(try isPure("""
        items.forEach { item in
            print(item)
        }
        """) == false)
    }

    @Test("a closure reading the clock is not pure")
    func nondeterminismIsImpure() throws {
        #expect(try isPure("let stamped = items.map { item in Date() }") == false)
    }

    @Test("a closure that can trap is not pure")
    func trappingIsImpure() throws {
        // A property test over generated inputs would hit the crash rather than falsify a law.
        #expect(try isPure("let names = items.map { item in item.name! }") == false)
    }

    @Test("a throwing closure is not pure")
    func throwingIsImpure() throws {
        #expect(try isPure("""
        let decoded = items.map { (item) throws -> Int in
            try parse(item)
        }
        """) == false)
    }
}
