import Foundation
import SwiftParser
@testable import SwiftEffectInference
import SwiftSyntax
import Testing

/// What building and consulting `ConstructionFacts` costs, on the shapes that once made it cost
/// too much — each pinned by its answer as well as its time, so a fix that changed the answer
/// would fail here too.
///
/// **The budgets are generous on purpose.** Each reproducer took tens of seconds before its fix
/// and takes well under one after, on a debug build; the bound sits far from both, so it fails on
/// the regression and on no machine CI runs on. `.timeLimit` is the backstop for a regression that
/// would not finish at all.
@Suite("ConstructionFacts — cost budget")
struct ConstructionCostTests {

    static let budget: Duration = .seconds(10)

    /// `layers` × `width` decodable types. Each holds three of the next layer's and decodes them in
    /// its own `init(from:)` — a decode site per property — and only the last type of the last
    /// layer holds `last`: the type that refutes, so every search has a long way to go.
    static func decodeGraph(layers: Int, width: Int, holding last: String = "Stamp") -> String {
        var lines = ["struct Stamp: Codable { var id = UUID() }"]
        for layer in 0..<layers {
            for node in 0..<width {
                var held: [String] = []
                if layer + 1 < layers {
                    held = [1, 2, width - 1].map { "L\(layer + 1)N\((node + $0) % width)" }
                } else if node == width - 1 {
                    held = [last]
                }
                let properties = held.enumerated().map { "let p\($0.offset): \($0.element)" }
                let decodes = held.enumerated().map { "p\($0.offset) = try c.decode(\($0.element).self)" }
                lines.append("""
                struct L\(layer)N\(node): Codable {
                    \(properties.joined(separator: "\n    "))
                    init(from decoder: Decoder) throws {
                        let c = try decoder.singleValueContainer()
                        \(decodes.joined(separator: "\n        "))
                    }
                }
                """)
            }
        }
        lines.append("func load(_ d: Data) -> L0N0? { try? JSONDecoder().decode(L0N0.self, from: d) }")
        return lines.joined(separator: "\n")
    }

    /// The types a construction witness passes through, outermost first, and what it ends in.
    static func path(_ refutation: PurityRefutation?) -> [String] {
        guard let refutation else { return [] }
        guard case .refutingConstruction(let type, let step, let cause) = refutation else { return ["\(refutation)"] }
        switch step {
        case .initializer(let signature): return ["\(type) \(signature)"] + path(cause)
        case .storedProperty(let property): return ["\(type).\(property)"] + path(cause)
        case .superclass(let base): return ["\(type): \(base)"] + path(cause)
        }
    }

    /// Every decode site searched the member-type graph afresh, on every pass: ~13 s on this
    /// reproducer before the search was answered once per type and pass, and the reason a folder
    /// holding several packages cost many times their sum.
    @Test("a decode searches the member-type graph once per type and pass", .timeLimit(.minutes(1)))
    func decodeGraphIsSearchedOncePerPass() throws {
        let tree = Parser.parse(source: Self.decodeGraph(layers: 10, width: 40))
        let load = try #require(tree.statements.lazy.compactMap { $0.item.as(FunctionDeclSyntax.self) }.first)
        let start = ContinuousClock.now
        let facts = ConstructionFacts.build(from: [tree])
        let refutation = PurityInferrer(constructionFacts: facts).refutation(for: load)
        let elapsed = ContinuousClock.now - start

        // Stamp, and every type whose decoding reaches the last of the last layer.
        #expect(facts.refutedTypeNames.count == 137)
        #expect(Self.path(refutation) == [
            "L0N0 init(from:)", "L1N1.p0", "L2N2.p0", "L3N3.p0", "L4N4.p2", "L5N3.p2", "L6N2.p2", "L7N1.p2",
            "L8N0.p2", "L9N39.p0", "Stamp.id", "references the nondeterminism marker `UUID`"
        ])
        #expect(elapsed < Self.budget, "built and judged in \(elapsed)")
    }

    /// The clock cannot see this on its own: once what names mean is kept, a search afresh is
    /// cheap on any graph a test can build. So the steps are counted.
    @Test("a decode is searched once per type in a pass, and a type that reaches nothing never again")
    func decodeIsSearchedOncePerType() throws {
        let (layers, width) = (6, 12)
        let source = Self.decodeGraph(layers: layers, width: width, holding: "Int")
        let facts = ConstructionFacts.build(from: [Parser.parse(source: source)]).memoised()
        let memo = try #require(facts.memo.instance)
        let index = Dictionary(uniqueKeysWithValues: facts.declarations.enumerated().map { ($1.qualifiedName, $0) })

        // What L0N0's decoding reaches, by the graph's own rule — itself included.
        var reached = ["L0N0"]
        var nodes: Set<Int> = [0]
        for layer in 1..<layers {
            nodes = Set(nodes.flatMap { node in [1, 2, width - 1].map { (node + $0) % width } })
            reached += nodes.map { "L\(layer)N\($0)" }
        }

        // Nothing in the graph refutes, so the first search steps into everything it reaches…
        #expect(facts.decodeRefutation(try #require(index["L0N0"])) == nil)
        #expect(memo.decodeSteps == reached.count)
        // …and that proves each of them reaches nothing: asked of any, there is no search.
        for name in reached { #expect(facts.decodeRefutation(try #require(index[name])) == nil) }
        #expect(memo.decodeSteps == reached.count)

        // Every other type searched once; asked again, every answer is the one kept.
        let refuting = facts.declarations.indices.filter { facts.decodeRefutation($0) != nil }
        #expect(refuting.map { facts.declarations[$0].qualifiedName } == ["Stamp"])
        let steps = memo.decodeSteps
        #expect(facts.declarations.indices.filter { facts.decodeRefutation($0) != nil } == refuting)
        #expect(memo.decodeSteps == steps, "asked again, \(memo.decodeSteps - steps) more steps")
    }

    /// swift-collections' `OrderedDictionary.Elements.SubSequence` declares `typealias SubSequence =
    /// Self`. `SubSequence.Index`, read through it, is `Outer.SubSequence.Index`; with no such type,
    /// the module-like head is dropped — and that is `SubSequence.Index` again, with the depth
    /// bound started afresh by `Self`. It recursed until the stack ran out: a package with that
    /// alias and any refutation crashed the build, and any judgement after it.
    @Test("a lookup that comes back to itself ends, and what else it reached still counts", .timeLimit(.minutes(1)))
    func lookupThatComesBackToItselfEnds() throws {
        let loop = """
        enum Outer {}
        extension Outer { struct SubSequence {} }
        extension Outer.SubSequence { typealias SubSequence = Self }
        struct Marker { let id = UUID() }
        func make() -> Any { SubSequence.Index() }
        """
        #expect(try constructionRefuted("make", in: loop) == false)

        let elsewhere = """
        struct Other { struct Index { let id = UUID() } }
        enum Elsewhere { typealias SubSequence = Other }
        """
        #expect(try constructionRefuted("make", in: loop, elsewhere))
    }

    /// A lookup is kept per scope, not per site — so the key has to say where in that scope the
    /// site is. From a class's inheritance clause the class's own members are out of reach; from
    /// its body they are in. Here `Base` means the outer class in one and the nested struct in the
    /// other, and both are asked from the same declaration.
    @Test("a name in an inheritance clause and the same name in the body are different questions")
    func inheritanceClauseAndBodyAreDifferentLookups() throws {
        #expect(try constructionRefuted("make", in: """
        class Base { var n = 0 }
        class Sub: Base { struct Base { let id = UUID() }; let helper = Base() }
        func make() -> Sub { Sub() }
        """))
        #expect(try constructionRefuted("make", in: """
        class Base { let id = UUID() }
        class Sub: Base { struct Base { var n = 0 }; let helper = Base() }
        func make() -> Sub { Sub() }
        """))
    }

    /// The decode search proves a type reaches nothing only when it searched every path from it.
    /// Searching `A`, `B`'s one way to the stamp is back through `A` — skipped, because `A` is still
    /// being searched — so that search proves nothing about `B`, and `Second` decoding a `B` later
    /// in the same pass must still find the stamp.
    @Test("a type skipped as already being searched is not taken to reach nothing")
    func decodeThroughACycle() throws {
        #expect(try constructionRefuted("make", in: """
        struct Stamp: Codable { var id = UUID() }
        struct A: Codable { let b: B; let c: C }
        struct B: Codable { let a: A? }
        struct C: Codable { let stamp: Stamp }
        struct First { init(d: Data) { _ = try? JSONDecoder().decode(A.self, from: d) } }
        struct Second { init(d: Data) { _ = try? JSONDecoder().decode(B.self, from: d) } }
        func make(_ d: Data) -> Second { Second(d: d) }
        """))
    }

    /// A decode answered in one pass is asked again in the next, against fuller facts: `B`'s
    /// `init(from:)` is known to refute only once a pass has judged its body, and `C`'s initializer
    /// decodes a `B` — so `C` refutes only from the pass after.
    @Test("a decode is answered again in every pass")
    func decodeAnswerFollowsThePass() throws {
        #expect(try constructionRefuted("make", in: """
        struct A { var id = UUID() }
        struct B: Decodable { init(from decoder: Decoder) throws { _ = A() } }
        struct C { init(x: Int) { _ = try? JSONDecoder().decode(B.self, from: Data()) } }
        func make() -> C { C(x: 1) }
        """))
    }
}
