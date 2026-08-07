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

    // MARK: - Locals bound by a nested closure

    @Test("a nested reduce(into:) accumulator is a local, not a capture")
    func nestedAccumulatorIsPure() throws {
        // `acc` is the inner closure's own `inout` parameter. Before nested parameters were
        // collected, only the *outer* closure's parameters counted as local, so this read as a
        // captured write — and the whole point of `reduce(into:)` is that the accumulator is local.
        #expect(try isPure("""
        let totals = groups.map { group in
            group.values.reduce(into: 0) { acc, value in acc += value }
        }
        """))
    }

    @Test("writing through a nested closure's named parameter is not a captured write")
    func nestedNamedParameterIsPure() throws {
        #expect(try isPure("""
        let counts = groups.map { group in
            group.rows.map { (row: Row) in row.width }
        }
        """))
    }

    @Test("writing through $0 is not a captured write")
    func shorthandParameterIsPure() throws {
        // A named parameter was always fair game; `$0` is the same thing spelled differently.
        #expect(try isPure("let widened = rows.map { $0.width = 10 }"))
    }

    @Test("a projected value is still a capture, despite the $")
    func projectedValueIsImpure() throws {
        // `$isPresented` is a Binding reaching out of the closure, not a shorthand parameter. Only
        // `$` followed by digits is a parameter.
        #expect(try isPure("""
        rows.forEach { row in
            $isPresented.wrappedValue = true
        }
        """) == false)
    }

    @Test("a captured write is still refuted when a nested closure is present")
    func captureWriteBesideNestedClosureIsImpure() throws {
        // The guard against the fix over-reaching: `total` is captured, and the nested closure
        // binding `value` must not launder it.
        #expect(try isPure("""
        groups.forEach { group in
            total += group.values.reduce(0) { running, value in running + value }
        }
        """) == false)
    }

    // MARK: - Effect and totality refuters

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

    // MARK: - The capture-write clause, asked on its own

    private func mutatesCapture(_ source: String) throws -> Bool {
        PurityInferrer().mutatesCapturedState(try closure(in: source))
    }

    @Test("the clause answers the capture question alone, not the purity question")
    func clauseIsIndependentOfTheOtherRefuters() throws {
        // The reason this is published separately: every one of these is impure, and none of them
        // writes to a capture. A caller inverting `isPure` to find captured writes gets all three
        // wrong.
        for source in [
            "items.forEach { item in print(item) }",
            "let stamped = items.map { item in Date() }",
            "let names = items.map { item in item.name! }"
        ] {
            #expect(try isPure(source) == false)
            #expect(try mutatesCapture(source) == false)
        }
    }

    @Test("the clause agrees with isPure when the capture write is the only refuter")
    func clauseAgreesWhenItIsTheOnlyRefuter() throws {
        let source = """
        items.forEach { item in
            total += item.amount
        }
        """
        #expect(try mutatesCapture(source))
        #expect(try isPure(source) == false)
    }

    @Test("reading a capture is not mutating one")
    func readingACaptureDoesNotMutate() throws {
        #expect(try mutatesCapture("""
        let children = files.filter { file in
            file.path.hasPrefix(currentPath)
        }
        """) == false)
    }

    @Test("the clause sees writes through a captured object")
    func writingThroughACaptureMutates() throws {
        #expect(try mutatesCapture("""
        items.forEach { item in
            cache.count = item.amount
        }
        """))
    }
}
