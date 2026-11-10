@testable import SwiftEffectInference
import SwiftParser
import SwiftSyntax
import Testing

/// Constructing a type runs its stored-property defaults and the initializer the call reaches —
/// code the function runs and its body does not show.
///
/// The hole, found on SwiftLintRuleStudio: `struct HealthRecommendation { let id = UUID() }`
/// constructed inside `generateRecommendations` was judged `.pure` by both consumers, and with a
/// synthesized `==` over `id` the determinism law `f(x) == f(x)` failed on correct code.
///
/// Every hole test here was watched failing with the facts ignored, and every control was watched
/// failing with the matching over-broad change; the mutants in `mutants/` are those changes.
@Suite("Constructing a type is part of the purity question")
struct ConstructionPurityTests {

    /// A function's verdicts: with facts built from its source, and without any.
    struct Judgement {
        let configured: PurityRefutation?
        let verdict: PurityVerdict
        let unconfigured: PurityRefutation?
    }

    /// The first `func` named `name` in `source`, judged against facts built from the same source.
    func judge(_ name: String, in source: String) throws -> Judgement {
        let tree = Parser.parse(source: source)
        let facts = ConstructionFacts.build(from: [tree])
        final class Finder: SyntaxVisitor {
            let name: String
            var found: FunctionDeclSyntax?

            init(name: String) { self.name = name; super.init(viewMode: .sourceAccurate) }
            override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
                if found == nil, node.name.text == name { found = node }
                return .visitChildren
            }
        }
        let finder = Finder(name: name)
        finder.walk(tree)
        let function = try #require(finder.found, "no func \(name)")
        let configured = PurityInferrer(constructionFacts: facts)
        return Judgement(
            configured: configured.refutation(for: function),
            verdict: configured.verdict(for: function),
            unconfigured: PurityInferrer().refutation(for: function)
        )
    }

    let healthRecommendation = """
    public struct HealthRecommendation: Identifiable, Sendable {
        public let id = UUID()
        public let title: String
    }
    """

    // MARK: - The hole

    @Test("the HealthRecommendation shape is refuted, and was not before")
    func healthRecommendationShapeIsRefuted() throws {
        let judged = try judge("generateRecommendations", in: healthRecommendation + """

        func generateRecommendations(_ titles: [String]) -> [HealthRecommendation] {
            var recommendations: [HealthRecommendation] = []
            for title in titles { recommendations.append(HealthRecommendation(title: title)) }
            return recommendations
        }
        """)
        #expect(judged.unconfigured == nil)
        #expect(judged.verdict == .refuted)
        #expect(judged.configured == .refutingConstruction(
            type: "HealthRecommendation", via: .storedProperty("id"), cause: .nondeterministicMarker("UUID")
        ))
    }

    @Test("every construction spelling reaches the fact", arguments: [
        "HealthRecommendation(title: t)",
        "HealthRecommendation.init(title: t)",
        "Models.HealthRecommendation(title: t)",
        "[t].map(HealthRecommendation.init)",
        "[t].map { HealthRecommendation(title: $0) }",
        "Rec(title: t)",
    ])
    func everySpellingReachesTheFact(expression: String) throws {
        let configured = try judge("f", in: healthRecommendation + """

        typealias Rec = HealthRecommendation
        func f(_ t: String) -> Any { \(expression) }
        """).configured
        #expect(configured != nil, "\(expression) was not refuted")
    }

    @Test("a stored default that constructs a refuted type refutes too — the fixpoint")
    func nestedFactTypePropagates() throws {
        let configured = try judge("f", in: healthRecommendation + """

        struct Report { let headline = HealthRecommendation(title: "x"); let score: Int }
        func f(_ s: Int) -> Report { Report(score: s) }
        """).configured
        let refutation = try #require(configured)
        guard case .refutingConstruction("Report", .storedProperty("headline"), let cause) = refutation else {
            Issue.record("expected Report.headline, got \(String(describing: configured))"); return
        }
        #expect(cause == .refutingConstruction(
            type: "HealthRecommendation", via: .storedProperty("id"), cause: .nondeterministicMarker("UUID")
        ))
    }

    @Test("an explicit initializer whose body generates an identity refutes the calls it accepts")
    func explicitInitializerBody() throws {
        let source = """
        struct Item {
            let id: UUID
            let title: String
            init(title: String) { self.id = UUID(); self.title = title }
            init(id: UUID, title: String) { self.id = id; self.title = title }
        }
        func fresh(_ t: String) -> Item { Item(title: t) }
        func injected(_ id: UUID, _ t: String) -> Item { Item(id: id, title: t) }
        """
        #expect(try judge("fresh", in: source).configured != nil)
        // The fixed shape — the identity arrives as an argument — must stay pure.
        #expect(try judge("injected", in: source).configured == nil)
    }

    @Test("a throwing function that constructs one is refuted, not pureButPartial")
    func partialFunctionIsRefuted() throws {
        let verdict = try judge("parse", in: healthRecommendation + """

        func parse(_ text: String) throws -> HealthRecommendation {
            guard !text.isEmpty else { throw ParseError.empty }
            return HealthRecommendation(title: text)
        }
        """).verdict
        #expect(verdict == .refuted)
    }

    @Test("a subclass inherits its superclass's construction")
    func superclassPropagates() throws {
        let configured = try judge("f", in: """
        class Base { let createdAt = Date() }
        final class Derived: Base { let name = "x" }
        func f() -> Derived { Derived() }
        """).configured
        #expect(configured != nil)
    }

    @Test("a clock in a class's var default refutes every construction")
    func classVarDefault() throws {
        #expect(try judge("f", in: """
        final class Session { var startedAt = Date() }
        func f() -> Session { Session() }
        """).configured != nil)
    }

    // MARK: - The controls

    /// The control that makes this a fix: mentioning the type is not constructing it.
    @Test("a parameter or return TYPE naming a refuted type stays pure")
    func typeMentionStaysPure() throws {
        let judged = try judge("titles", in: healthRecommendation + """

        func titles(of recommendations: [HealthRecommendation]) -> [String] {
            let typed: [HealthRecommendation] = recommendations
            return typed.compactMap { $0 as? HealthRecommendation }.map(\\.title)
        }
        """)
        #expect(judged.configured == nil)
        #expect(judged.verdict == .pure)
    }

    @Test("a metatype and a static member are not constructions")
    func metatypeStaysPure() throws {
        let configured = try judge("f", in: healthRecommendation + """

        func f() -> String { String(describing: HealthRecommendation.self) }
        """).configured
        #expect(configured == nil)
    }

    @Test("passing the defaulted memberwise label is the fixed shape, and stays pure")
    func passingTheDefaultedLabelStaysPure() throws {
        let source = """
        struct Draft { var id = UUID(); var title: String }
        func fresh(_ t: String) -> Draft { Draft(title: t) }
        func injected(_ id: UUID, _ t: String) -> Draft { Draft(id: id, title: t) }
        """
        #expect(try judge("fresh", in: source).configured != nil)
        #expect(try judge("injected", in: source).configured == nil)
    }

    @Test("a static or lazy default does not run on construction")
    func staticAndLazyDefaultsDoNotRefute() throws {
        let configured = try judge("f", in: """
        struct Clock { static let boot = Date(); lazy var firstRead = Date(); let offset: Int }
        func f(_ o: Int) -> Clock { Clock(offset: o) }
        """).configured
        #expect(configured == nil)
    }

    @Test("a type with inert defaults stays pure")
    func inertDefaultsStayPure() throws {
        let configured = try judge("f", in: """
        struct Page { var size = 20; let title: String }
        func f(_ t: String) -> Page { Page(title: t) }
        """).configured
        #expect(configured == nil)
    }

    @Test("a name declared in the innermost enclosing declaration resolves to it, and nothing else")
    func lexicalResolutionWhereCertain() throws {
        let source = """
        struct Clean {
            struct Item { let title: String }
            static func make(_ t: String) -> Item { Item(title: t) }
        }
        struct Dirty { struct Item { let id = UUID() } }
        func qualified(_ t: String) -> Any { Clean.Item(title: t) }
        """
        #expect(try judge("make", in: source).configured == nil)
        #expect(try judge("qualified", in: source).configured == nil)
    }

    /// Lookup from an extension, or through a superclass's nested types, is approximated — so there
    /// every declaration of the name Swift could reach is a candidate. This is the deliberate
    /// over-refutation: `make` reaches the clean `Clean.Item` in fact, and is refuted here.
    @Test("outside the innermost declaration, any reachable candidate refuting refutes")
    func unionWhereNotCertain() throws {
        #expect(try judge("make", in: """
        struct Item { let id = UUID(); let title: String }
        struct Clean { struct Item { let title: String } }
        extension Clean { static func make(_ t: String) -> Item { Item(title: t) } }
        """).configured != nil)
    }

    @Test("a namesake nested in an unrelated type is not reachable, so not a candidate")
    func unreachableNamesakeIsNotACandidate() throws {
        #expect(try judge("make", in: """
        struct Clean { struct Item { let title: String } }
        struct Dirty { struct Item { let id = UUID(); let title: String } }
        extension Clean { static func make(_ t: String) -> Item { Item(title: t) } }
        """).configured == nil)
    }

    /// The case union exists for: Swift finds `Base.Item` through the superclass, while a lexical
    /// walk from `Derived` sees only the clean top-level `Item`.
    @Test("a superclass's nested type is not hidden by a clean top-level namesake")
    func superclassNestedTypeIsACandidate() throws {
        let configured = try judge("make", in: """
        struct Item { let title: String }
        class Base { struct Item { let id = UUID(); let title: String } }
        final class Derived: Base { func make(_ t: String) -> Any { Item(title: t) } }
        """).configured
        #expect(configured != nil)
    }
}
