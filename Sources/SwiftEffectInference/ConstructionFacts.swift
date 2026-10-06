import SwiftSyntax

/// What constructing each of a package's types runs — the code a function executes when it writes
/// `T(…)` and that its own body does not show.
///
/// ## Why the oracle needs it
///
/// `PurityInferrer` judges one declaration at a time. So in
///
///     public struct HealthRecommendation: Identifiable { public let id = UUID(); let title: String }
///
///     func generateRecommendations(_ titles: [String]) -> [HealthRecommendation] {
///         titles.map { HealthRecommendation(title: $0) }
///     }
///
/// `generateRecommendations` reached nothing: the `UUID()` lives in a stored-property default of a
/// type declared elsewhere, and the call site names only the type. Measured on SwiftLintRuleStudio
/// before this existed, both consumers called `generateRecommendations` and `analyze` pure,
/// SwiftInferProperties advised `/// @lint.effect pure` for them, and once such a function's result
/// was `Equatable` the synthesized determinism law `f(x) == f(x)` **failed on correct code** — every
/// call minted a new `id`. `let id = UUID()` is the stock `Identifiable` idiom, so this is common.
///
/// ## What it records
///
/// For every struct, class, actor and enum — including those declared inside a function, and
/// members inside `#if` — the code that runs on construction: stored-property defaults (judged
/// against their annotation, so `var created: Date = .now` is `Date.now`), property wrappers
/// declared in the package, each initializer's body and defaulted parameters (including those in
/// extensions, and in protocol extensions, which belong to every conformer), the implicit `init()`
/// of a root class, and the superclass. Built once from every source, to a fixpoint — a default
/// that constructs another refuted type refutes too — and handed to
/// `PurityInferrer(constructionFacts:)`. Pass production sources only: a test file's
/// `struct Item { let id = UUID() }` would otherwise be a candidate for a production `Item(…)`.
///
/// ## What counts as a construction
///
/// A call that builds a type: `T(…)`, `T<G>(…)`, `T.init(…)`, `T.self.init(…)`, `Outer.T(…)`,
/// `Self(…)`, a typealias of any of these; `self.init(…)` and `super.init(…)` in an initializer,
/// and the implicit `super.init()` a designated initializer gets; `T.init` and `T.init(label:)` as
/// function values; `decode` and `decodeIfPresent` of `T.self` (and of `[T].self`, and of the
/// types `T`'s properties hold); a local property wrapper; and a base-less `.init(…)` typed by its
/// context — a binding's or parameter's annotation, the enclosing function's return type, or an
/// assignment's target, through `?`, `??`, ternaries, `try`, tuples, array and dictionary literals
/// and `if`/`switch` expressions. A labelled `.init(…)` with no such context is matched against
/// every type whose initializers take its arguments. **Never a bare mention of `T`**: a parameter
/// or return type, `T.self` passed anywhere but a decode, and a static member stay pure — the house
/// rule that moved `contentsOf` from a token match to a callee match.
///
/// ## Any doubt refutes
///
/// - **Names.** A spelling resolves among the declarations Swift could reach from where it is
///   written: the enclosing types and, for a class, its superclasses' nested types; the outer
///   types of an extended nested type; the function bodies within them; and the top level. Exactly
///   one is chosen only when the innermost enclosing *declaration* (not an extension) declares it
///   and nothing at the site — a generic parameter, a local type or typealias — can shadow it.
///   Otherwise every reachable declaration is a candidate, and any of them refuting refutes. A
///   head no reachable type names (a module, `SwiftUI.Section`) is dropped and the rest resolved.
///   `Self` means every subclass of a non-final class, and every conformer in a protocol extension.
/// - **Typealiases.** By the same rule: the innermost declaration's own alias when it declares
///   one, and it shadows every outer namesake. Otherwise every alias of that name in the package —
///   and the name itself, which may be a framework type's — so a `typealias UUID = String` in one
///   type never hides a `UUID` default in another. A target is read where its alias is written.
/// - **Initializers.** A call no known initializer accepts reached one the table cannot see —
///   macro-generated, inherited from outside the package, or matched by a rule finer than this
///   one's. It refutes if anything constructing that type can.
///
/// The cost is over-refutation: where a reachable namesake mints an identity, where a module
/// prefix names a framework type that shares a package type's name, and where a class's
/// convenience initializer is judged with `Self` covering its subclasses.
///
/// ## What it deliberately leaves out
///
/// Partiality: a trapping initializer is a trap in a callee, and the oracle follows no other
/// callee's traps either. A `lazy` default runs on first access, which is the reader's impurity,
/// as a computed property's getter is; so does a `@StateObject` initial value, an autoclosure. A
/// `static` default runs once per process. And these constructions are not seen, each pinned by a
/// test: an unlabelled `.init(…)` with no context; a generic parameter or metatype value
/// constructed (`T()`, `type(of: x).init()`); literal conversion through `ExpressibleBy…Literal`;
/// an enum case's associated-value default; a `deinit`; and a property wrapper the package does
/// not declare.
public struct ConstructionFacts: Sendable, Equatable {

    /// No facts. A `PurityInferrer` holding this answers exactly as before the table existed, at
    /// the same cost.
    public static let empty = ConstructionFacts()

    var declarations: [ConstructionDeclaration] = []
    var indicesByBareName: [String: [Int]] = [:]
    /// Every `typealias A = B.C`, by the alias's bare name. A list, because each type may declare
    /// its own `A`, and `#if` branches several.
    var aliases: [String: [AliasDeclaration]] = [:]
    var protocolNames: Set<String> = []
    /// A protocol's own inheritance clause, by bare name, compositions spelled out.
    var protocolParents: [String: [String]] = [:]
    /// Each stored property's declared type, by qualified type name and property. A list, because
    /// a qualified name may be declared more than once (`#if` branches, several targets).
    var memberTypes: [String: [String: [MemberType]]] = [:]
    /// Stored, not computed: the inferrer asks on every body it judges.
    var hasRefutations = false
    /// What has been worked out already — attached by `build(from:)` for its passes, and by a walk
    /// over a body for that walk. Never part of what the table says, nor of its equality.
    var memo = ConstructionMemo.Slot()

    /// No facts — the same as `ConstructionFacts.empty`.
    public init() {}

    /// Whether there is anything to consult. The inferrer skips the construction pass entirely
    /// when there is not, which is what keeps an unconfigured `PurityInferrer` at its measured cost.
    public var isEmpty: Bool { !hasRefutations }

    /// Qualified names of every type with at least one refuting construction path, sorted.
    public var refutedTypeNames: [String] {
        Array(Set(declarations.filter { $0.anyRefutation != nil }.map(\.qualifiedName))).sorted()
    }

    /// The witness for constructing `qualifiedName` by any initializer — what a consumer reports
    /// *at the type*, where the line to change is.
    public func refutation(constructing qualifiedName: String) -> PurityRefutation? {
        let bare = qualifiedName.split(separator: ".").last.map(String.init) ?? qualifiedName
        return indices(bare)
            .lazy
            .filter { self.declarations[$0].qualifiedName == qualifiedName }
            .compactMap { self.declarations[$0].anyRefutation }
            .first
    }

    /// Whether `token` could name something this table indexes. A cheap pre-filter only: a type is
    /// never matched as a bare token, only at a construction. `init` covers the constructions that
    /// do not name their type — `self.init`, `super.init` and `.init` — and `decode` the decodes.
    func mentions(_ token: String) -> Bool {
        token == "Self" || token == "init" || token == "decode" || token == "decodeIfPresent"
            || indicesByBareName[token] != nil || aliases[token] != nil
    }

    // MARK: - Building

    /// Builds the table from every source in a package, to a fixpoint.
    ///
    /// Pass sources in a **fixed** order. Which types are refuted does not depend on it — wherever
    /// a name, a typealias included, has several candidates, every one is consulted and none is
    /// chosen by when it was collected — but which witness is reported first among several does.
    public static func build(from sources: [SourceFileSyntax]) -> ConstructionFacts {
        let collector = TypeShapeCollector(viewMode: .sourceAccurate)
        for source in sources { collector.walk(source) }
        let raws = collector.finish()

        var facts = ConstructionFacts(declarations: raws.map(\.unjudged), collector: collector)
        // One memo for every pass: what names mean is kept throughout, what is refuted per pass.
        let memo = ConstructionMemo()
        facts.memo.instance = memo

        // Monotone: a better-informed inferrer refutes a superset of what a less-informed one
        // does, and a witness once found is kept, so each pass only fills empty slots. It stops
        // when a pass fills none, and cannot run longer than there are slots. No wall clock, so
        // the table is a function of its sources.
        var bound = 1
        var refuted = 0
        var pass = 0
        while pass <= bound {
            memo.startPass()
            let inferrer = PurityInferrer(constructionFacts: facts)
            let fresh = raws.map { $0.evaluate(with: inferrer, facts: facts) }
            if pass == 0 { bound = fresh.reduce(2) { $0 + $1.slotCount } }
            var next = facts
            next.declarations = zip(fresh, facts.declarations).map { $0.keeping($1) }
            next.hasRefutations = next.declarations.contains { $0.anyRefutation != nil }
            let nowRefuted = next.declarations.reduce(0) { $0 + $1.refutedSlotCount }
            facts = next
            if nowRefuted == refuted { break }
            refuted = nowRefuted
            pass += 1
        }
        // The table leaves the build without it: a consumer may share the table between threads.
        facts.memo.instance = nil
        return facts
    }

    /// Unjudged declarations and what the collector saw — enough to resolve names while
    /// collecting, and the starting point of the fixpoint.
    init(declarations: [ConstructionDeclaration], collector: TypeShapeCollector) {
        self.init(
            declarations: declarations,
            protocolNames: collector.protocolNames,
            protocolParents: collector.protocolParents
        )
        aliases = collector.aliases
        memberTypes = collector.memberTypes
    }

    init(declarations: [ConstructionDeclaration], protocolNames: Set<String>, protocolParents: [String: [String]]) {
        self.declarations = declarations
        self.protocolNames = protocolNames
        self.protocolParents = protocolParents
        for (index, declaration) in declarations.enumerated() {
            indicesByBareName[declaration.bareName, default: []].append(index)
        }
    }

    /// The refutation constructing anything in `syntax` incurs — the first in source order.
    ///
    /// Walked once per pass: a protocol extension's initializer belongs to every conformer, and
    /// is judged as each one's, but what its body constructs does not depend on whose it is.
    func refutation(constructingIn syntax: Syntax) -> PurityRefutation? {
        guard let memo = memo.instance else { return memoised().refutation(constructingIn: syntax) }
        if let known = memo.walks[syntax] { return known }
        let checker = ConstructionChecker(facts: self)
        checker.walk(syntax)
        memo.walks.updateValue(checker.refutation, forKey: syntax)
        return checker.refutation
    }

    /// `self` with a memo: the build's, while one is attached, or else a new one, kept as long as
    /// the copy is — for a walk over one body, or one question asked outside a build.
    func memoised() -> ConstructionFacts {
        guard memo.instance == nil else { return self }
        var facts = self
        facts.memo.instance = ConstructionMemo()
        return facts
    }
}
