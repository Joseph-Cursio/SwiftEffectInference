@testable import SwiftEffectInference
import SwiftParser
import SwiftSyntax
import Testing

extension ConstructionPurityTests {

    // MARK: - Initializers that do not show their work

    /// An extension initializer keeps the memberwise one, so the type's `var` defaults stay
    /// conditional on the memberwise call — but the extension initializer itself runs them all.
    @Test("an extension initializer runs a struct's var defaults")
    func extensionInitializerRunsVarDefaults() throws {
        let source = """
        struct Draft { var id = UUID(); var title: String }
        extension Draft { init(title: String, tag: Int) { self.title = title + String(tag) } }
        func tagged(_ t: String) -> Draft { Draft(title: t, tag: 1) }
        func memberwise(_ id: UUID, _ t: String) -> Draft { Draft(id: id, title: t) }
        """
        #expect(try judge("tagged", in: source).configured != nil)
        #expect(try judge("memberwise", in: source).configured == nil)
    }

    @Test("a delegating initializer refutes when the one it delegates to does")
    func delegatingInitializerIsFollowed() throws {
        let source = """
        struct Stamp {
            let id: UUID
            let name: String
            init(id: UUID, name: String) { self.id = id; self.name = name }
            init(fresh name: String) { self.id = UUID(); self.name = name }
        }
        extension Stamp {
            init(name: String) { self.init(fresh: name) }
            init(name: String, id: UUID) { self.init(id: id, name: name) }
        }
        func viaFresh(_ n: String) -> Stamp { Stamp(name: n) }
        func viaInjected(_ n: String, _ id: UUID) -> Stamp { Stamp(name: n, id: id) }
        """
        #expect(try judge("viaFresh", in: source).configured != nil)
        #expect(try judge("viaInjected", in: source).configured == nil)
    }

    @Test("super.init is a construction of the superclass")
    func superInitializerIsFollowed() throws {
        let source = """
        class Base {
            let id: UUID
            init(id: UUID) { self.id = id }
            init() { self.id = UUID() }
        }
        final class Fresh: Base { init(name: String) { super.init() } }
        final class Injected: Base { init(name: String, id: UUID) { super.init(id: id) } }
        func fresh(_ n: String) -> Fresh { Fresh(name: n) }
        func injected(_ n: String, _ id: UUID) -> Injected { Injected(name: n, id: id) }
        """
        #expect(try judge("fresh", in: source).configured != nil)
        #expect(try judge("injected", in: source).configured == nil)
    }

    @Test("a class with no matching initializer of its own reaches its superclass's")
    func inheritedInitializerIsFollowed() throws {
        let configured = try judge("f", in: """
        class Base { let id: UUID; init(stamp: Int) { self.id = UUID() } }
        final class Derived: Base {}
        func f() -> Derived { Derived(stamp: 1) }
        """).configured
        guard case .refutingConstruction("Derived", .superclass("Base"), _) = try #require(configured) else {
            Issue.record("expected the superclass witness, got \(String(describing: configured))"); return
        }
    }

    // MARK: - A base-less .init

    @Test("a base-less .init takes its type from the context", arguments: [
        "func f(_ t: String) -> HealthRecommendation { .init(title: t) }",
        "func f(_ t: String) -> HealthRecommendation? { return .init(title: t) }",
        "func f(_ t: String) -> [HealthRecommendation] { [.init(title: t)] }",
        "func f(_ t: String) -> Int { let r: HealthRecommendation = .init(title: t); return r.title.count }",
    ])
    func contextualInitializerIsAttributed(function: String) throws {
        let configured = try judge("f", in: healthRecommendation + "\n" + function).configured
        #expect(configured != nil, "\(function) was not refuted")
    }

    /// With no context to type it, a labelled `.init(…)` is matched by shape against every type —
    /// in a closure, whose return type is inferred, and in an argument, whose type is the callee's.
    @Test("a labelled base-less .init with no context is matched against every type", arguments: [
        "func f(_ ts: [String]) -> [HealthRecommendation] { ts.map { .init(title: $0) } }",
        "func f(_ t: String) -> Int { count(.init(title: t)) }",
    ])
    func contextlessLabelledInitializerIsMatchedByShape(function: String) throws {
        let configured = try judge("f", in: healthRecommendation + """

        func count(_ r: HealthRecommendation) -> Int { r.title.count }
        \(function)
        """).configured
        #expect(configured != nil, "\(function) was not refuted")
    }

    /// The known miss, pinned so a change that closes it is noticed. An unlabelled `.init()` with
    /// no context could be any type at all; matching it by shape would refute most SwiftUI code.
    @Test("an unlabelled base-less .init with no context stays open")
    func contextlessUnlabelledInitializerStaysOpen() throws {
        let configured = try judge("f", in: """
        struct Stamp { var id = UUID() }
        func use(_ s: Stamp) -> Int { 1 }
        func f() -> Int { use(.init()) }
        """).configured
        #expect(configured == nil)
    }

    /// A call no declared initializer accepts reached one the table cannot see — here a protocol
    /// extension's. What runs is that initializer and the stored defaults, never a sibling's body.
    @Test("an unseen initializer does not borrow a sibling initializer's body")
    func unseenInitializerDoesNotBorrowASibling() throws {
        let configured = try judge("f", in: """
        protocol Named { init(name: String) }
        extension Named { init(upper: String) { self.init(name: upper.uppercased()) } }
        struct Tag: Named {
            let name: String
            init(name: String) { self.name = name }
            init(stampedAt: Int) { self.name = "\\(Date())" }
        }
        func f(_ s: String) -> Tag { Tag(upper: s) }
        """).configured
        #expect(configured == nil)
    }

    /// Construction is judged on the transparency half only. A trap in an initializer is a trap in a
    /// callee, which the oracle does not follow for any other callee either.
    @Test("a trapping initializer is not followed — totality stops at the call, as for any callee")
    func trappingInitializerIsNotFollowed() throws {
        let judged = try judge("f", in: """
        struct Percent { let value: Double; init(_ v: Double) { precondition(v >= 0); value = v } }
        func f(_ x: Double) -> Percent { Percent(x) }
        """)
        #expect(judged.configured == nil)
        #expect(judged.verdict == .pure)
    }

    @Test("an unconfigured inferrer answers exactly as before")
    func emptyFactsChangeNothing() throws {
        let caller = "func f() -> HealthRecommendation { HealthRecommendation(title: \"x\") }"
        let tree = Parser.parse(source: healthRecommendation + "\n" + caller)
        let function = try #require(tree.statements.compactMap { $0.item.as(FunctionDeclSyntax.self) }.first)
        #expect(PurityInferrer(constructionFacts: .empty).verdict(for: function) == .pure)
        #expect(PurityInferrer().verdict(for: function) == .pure)
        #expect(ConstructionFacts.empty.isEmpty)
        #expect(ConstructionFacts.build(from: [tree]).isEmpty == false)
    }

    @Test("the witness reads as a sentence")
    func witnessDescription() throws {
        let refutation = PurityRefutation.refutingConstruction(
            type: "HealthRecommendation", via: .storedProperty("id"), cause: .nondeterministicMarker("UUID")
        )
        #expect(refutation.description
            == "constructs `HealthRecommendation`, and the default value of its stored property `id` "
            + "references the nondeterminism marker `UUID`")
    }

    @Test("closures, accessors and default arguments reach the fact too")
    func otherEntryPoints() throws {
        let tree = Parser.parse(source: healthRecommendation + """

        struct Holder {
            var latest: HealthRecommendation { HealthRecommendation(title: "x") }
            func g(_ r: HealthRecommendation = HealthRecommendation(title: "y")) -> String { r.title }
            let make = { HealthRecommendation(title: "z") }
        }
        """)
        let facts = ConstructionFacts.build(from: [tree])
        let inferrer = PurityInferrer(constructionFacts: facts)
        final class Finder: SyntaxVisitor {
            var accessor: AccessorBlockSyntax?; var function: FunctionDeclSyntax?; var closure: ClosureExprSyntax?

            override func visit(_ node: AccessorBlockSyntax) -> SyntaxVisitorContinueKind {
                accessor = accessor ?? node
                return .visitChildren
            }
            override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
                function = function ?? node
                return .visitChildren
            }
            override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
                closure = closure ?? node
                return .visitChildren
            }
        }
        let finder = Finder(viewMode: .sourceAccurate)
        finder.walk(tree)
        let accessor = try #require(finder.accessor)
        let function = try #require(finder.function)
        let closure = try #require(finder.closure)
        #expect(inferrer.refutation(for: accessor) != nil)
        let viaDefault = try #require(inferrer.refutation(for: function))
        guard case .refutingDefaultArgument("r", .refutingConstruction) = viaDefault else {
            Issue.record("default argument did not carry the construction: \(viaDefault)"); return
        }
        #expect(inferrer.refutation(for: closure) != nil)
    }

    // MARK: - The table itself

    @Test("a subclass of a refuted class is a refuted type, through its superclass")
    func subclassIsARefutedType() throws {
        let facts = ConstructionFacts.build(from: [
            Parser.parse(source: """
            class Base { let id = UUID() }
            final class Sub: Base {}
            """),
        ])
        #expect(facts.refutedTypeNames == ["Base", "Sub"])
        let refutation = try #require(facts.refutation(constructing: "Sub"))
        guard case .refutingConstruction("Sub", .superclass("Base"), _) = refutation else {
            Issue.record("Sub was not refuted through Base: \(refutation)"); return
        }
    }

    @Test("a witness, once found, is kept: a later pass does not replace it with a longer one")
    func witnessIsKept() throws {
        // The first pass finds `stamp`; the second also finds `inner`, which comes first.
        let facts = ConstructionFacts.build(from: [
            Parser.parse(source: """
            struct Inner { let id = UUID() }
            struct Outer { let inner = Inner(); let stamp = Date() }
            """),
        ])
        let refutation = try #require(facts.refutation(constructing: "Outer"))
        guard case .refutingConstruction("Outer", .storedProperty("stamp"), _) = refutation else {
            Issue.record("the witness was replaced: \(refutation)"); return
        }
    }

    @Test("a call no known initializer accepts refutes if any way of constructing the type can")
    func unseenInitializer() throws {
        // A macro may generate `init(at:)`; what it runs is not in the table.
        #expect(try judge("f", in: """
        struct Event { var at: Date; init(now: Date = Date()) { at = now } }
        func f() -> Event { Event(at: .distantPast) }
        """).configured != nil)
        // The control: a raw-value enum's synthesized init(rawValue:) runs nothing.
        #expect(try judge("f", in: """
        enum Mode: String { case fast; init(seed: Int = Int.random(in: 0...1)) { self = .fast } }
        func f() -> Mode? { Mode(rawValue: "fast") }
        """).configured == nil)
    }

    @Test("the context of a base-less .init decides its type")
    func contextDecidesTheType() throws {
        // Matched by shape, `.init(title:)` could be HealthRecommendation; the return type says not.
        #expect(try judge("f", in: healthRecommendation + """

        struct Clean { var title: String }
        func f(_ t: String) -> Clean { .init(title: t) }
        """).configured == nil)
        // And an unlabelled `.init()`, which no shape could match, is typed by it.
        #expect(try judge("f", in: """
        struct Report { let id = UUID() }
        func f() -> Report { .init() }
        """).configured != nil)
    }
}
