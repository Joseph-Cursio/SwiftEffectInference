import SwiftParser
import Testing
@testable import SwiftEffectInference

/// A typealias is a name like any other: it means the alias Swift picks where it is written, and
/// where that is in doubt, every alias of the name. Aliases were once followed by bare name, first
/// collected first — so which types refuted turned on source order, and in one order a `UUID`
/// default behind a nested `typealias Stamp` went unseen.
@Suite("Construction purity: typealiases")
struct ConstructionTypealiasTests {

    // MARK: - Namesakes

    @Test("a nested alias resolves in its own type, whatever order its namesakes come in")
    func nestedAliasNamesakes() throws {
        let plain = "struct A { typealias Stamp = String; var s: Stamp = .init() }\nfunc makeA() -> A { A() }"
        let minting = "struct B { typealias Stamp = UUID; let s: Stamp = .init() }\nfunc makeB() -> B { B() }"
        for sources in [[plain, minting], [minting, plain], [plain + "\n" + minting], [minting + "\n" + plain]] {
            #expect(try constructionRefutation(of: "makeB", in: sources) != nil, "\(sources)")
            #expect(try constructionRefutation(of: "makeA", in: sources) == nil, "\(sources)")
            let facts = ConstructionFacts.build(from: sources.map { Parser.parse(source: $0) })
            #expect(facts.refutedTypeNames == ["B"], "\(sources)")
        }
    }

    @Test("a construction through an alias takes the alias its own type declares")
    func constructionThroughNestedAlias() throws {
        let clean = """
        struct Plain { var n = 0 }
        struct A { typealias Item = Plain; func make() -> Item { Item() } }
        """
        let dirty = """
        struct Minted { let id = UUID() }
        struct B { typealias Item = Minted; func mint() -> Item { Item() } }
        """
        for sources in [[clean, dirty], [dirty, clean]] {
            #expect(try constructionRefutation(of: "mint", in: sources) != nil, "\(sources)")
            #expect(try constructionRefutation(of: "make", in: sources) == nil, "\(sources)")
        }
    }

    @Test("an alias in one type does not take a framework type's name from another")
    func aliasDoesNotHijackAFrameworkName() throws {
        let source = """
        struct Legacy { typealias UUID = String; var id: UUID = .init() }
        struct Item { let id: UUID = .init(); let title: String }
        func makeItem(_ t: String) -> Item { Item(title: t) }
        func makeLegacy() -> Legacy { Legacy() }
        """
        #expect(try constructionRefuted("makeItem", in: source))
        #expect(try !constructionRefuted("makeLegacy", in: source))
    }

    /// Where the enclosing declaration does not settle it — in a nested type, an extension, or
    /// between `#if` branches — every alias of the name is a candidate, and any of them refuting
    /// refutes.
    @Test("an alias the site does not settle is every alias of the name", arguments: [
        """
        struct T {
        #if os(Linux)
            typealias Stamp = String
        #else
            typealias Stamp = UUID
        #endif
            let s: Stamp = .init()
        }
        func f() -> T { T() }
        """,
        """
        struct T {
        #if os(Linux)
            typealias Stamp = UUID
        #else
            typealias Stamp = String
        #endif
            let s: Stamp = .init()
        }
        func f() -> T { T() }
        """,
        """
        #if canImport(UIKit)
        typealias Stamp = String
        #else
        typealias Stamp = UUID
        #endif
        struct T { let s: Stamp = .init() }
        func f() -> T { T() }
        """,
        """
        struct Outer {
            typealias Stamp = UUID
            struct T { let s: Stamp = .init() }
        }
        struct Other { typealias Stamp = String }
        func f() -> Outer.T { Outer.T() }
        """,
        """
        struct Other { typealias Stamp = String }
        struct T { let n: Int }
        extension T { typealias Stamp = UUID; init(stamp: Stamp = .init()) { n = 0 } }
        func f() -> T { T() }
        """
    ])
    func unsettledAliasIsAUnion(source: String) throws {
        #expect(try constructionRefuted("f", in: source), "\(source)")
    }

    // MARK: - Shapes of alias

    @Test("a single alias still resolves", arguments: [
        "typealias Stamp = UUID\nstruct T { let s: Stamp = .init() }\nfunc f() -> T { T() }",
        "struct T { typealias Stamp = UUID; let s: Stamp = .init() }\nfunc f() -> T { T() }",
        "struct T { typealias Stamp = Date; var at: Stamp = .now; let n: Int }\nfunc f(_ n: Int) -> T { T(n: n) }",
        "struct T { let s: Stamp = .init() }\nextension T { typealias Stamp = UUID }\nfunc f() -> T { T() }",
        """
        struct T { typealias Stamp = Date; let at: Stamp; init(at: Stamp = .now) { self.at = at } }
        func f() -> T { T() }
        """
    ])
    func singleAlias(source: String) throws {
        #expect(try constructionRefuted("f", in: source), "\(source)")
    }

    @Test("a chain of aliases is followed to its end, each link read where it is written")
    func aliasChain() throws {
        #expect(try constructionRefuted("f", in: """
        typealias Stamp = Token
        typealias Token = Mark
        typealias Mark = UUID
        struct T { let s: Stamp = .init() }
        func f() -> T { T() }
        """))
        let chained = """
        struct B { typealias Stamp = Token; typealias Token = UUID; let s: Stamp = .init() }
        func makeB() -> B { B() }
        """
        let namesake = "struct A { typealias Token = String; var t: Token = .init() }\nfunc makeA() -> A { A() }"
        for sources in [[chained, namesake], [namesake, chained]] {
            #expect(try constructionRefutation(of: "makeB", in: sources) != nil, "\(sources)")
            #expect(try constructionRefutation(of: "makeA", in: sources) == nil, "\(sources)")
        }
    }

    @Test("an alias heading a qualified spelling is followed", arguments: [
        """
        typealias Clock = ContinuousClock
        struct T { var start: Clock.Instant = .now; let n: Int }
        func f(_ n: Int) -> T { T(n: n) }
        """,
        "struct T { typealias Clock = ContinuousClock; var start: Clock.Instant = .now }\nfunc f() -> T { T() }"
    ])
    func aliasHeadingAQualifiedSpelling(source: String) throws {
        #expect(try constructionRefuted("f", in: source), "\(source)")
    }

    @Test("an alias to a nested type reaches it", arguments: [
        """
        enum Store { struct Token { let id = UUID() } }
        typealias Stamp = Store.Token
        struct T { var s: Stamp = .init(); let n: Int }
        func f(_ n: Int) -> T { T(n: n) }
        """,
        """
        struct T { struct Token { let id = UUID() }; typealias Stamp = Token; let s: Stamp = .init() }
        func f() -> T { T() }
        """,
        """
        enum Store { struct Token { let id = UUID() } }
        typealias Stamp = Store.Token
        func f() -> Any { Stamp() }
        """,
        "struct T { typealias Instant = ContinuousClock.Instant; var start: Instant = .now }\nfunc f() -> T { T() }"
    ])
    func aliasToANestedType(source: String) throws {
        #expect(try constructionRefuted("f", in: source), "\(source)")
    }

    @Test("an alias's target is read where the alias is written, not matched by bare name")
    func aliasTargetIsReadInItsScope() throws {
        let clean = """
        struct A { struct Token { var n = 0 }; typealias Stamp = Token; func make() -> Stamp { Stamp() } }
        """
        let dirty = """
        struct B { struct Token { let id = UUID() }; typealias Stamp = Token; func mint() -> Stamp { Stamp() } }
        """
        for sources in [[clean, dirty], [dirty, clean]] {
            #expect(try constructionRefutation(of: "mint", in: sources) != nil, "\(sources)")
            #expect(try constructionRefutation(of: "make", in: sources) == nil, "\(sources)")
        }
    }

    // MARK: - Qualified spellings

    /// `Outer.Stamp` names the alias `Outer` declares: it is followed like a head alias, and a
    /// framework type behind it is judged — not only a package type, which the head-dropping
    /// fallback already reached.
    @Test("an alias named as a member of its type is followed", arguments: [
        "enum Outer { typealias Stamp = UUID }\nstruct T { let s: Outer.Stamp = .init() }\nfunc f() -> T { T() }",
        """
        enum Outer { enum Inner { typealias Stamp = UUID } }
        struct T { let s: Outer.Inner.Stamp = .init() }
        func f() -> T { T() }
        """,
        """
        enum Outer {}
        extension Outer { typealias Stamp = Date }
        struct T { var at: Outer.Stamp = .now; let n: Int }
        func f(_ n: Int) -> T { T(n: n) }
        """,
        """
        enum Outer { typealias Clock = ContinuousClock }
        struct T { var start: Outer.Clock.Instant = .now }
        func f() -> T { T() }
        """,
        """
        typealias Space = Outer
        enum Outer { typealias Stamp = UUID }
        struct T { let s: Space.Stamp = .init() }
        func f() -> T { T() }
        """
    ])
    func memberAlias(source: String) throws {
        #expect(try constructionRefuted("f", in: source), "\(source)")
    }

    @Test("a member alias is the one its owner declares, not a namesake elsewhere")
    func memberAliasTakesItsOwner() throws {
        #expect(try !constructionRefuted("f", in: """
        enum Outer { typealias Stamp = String }
        enum Other { typealias Stamp = UUID }
        struct T { var s: Outer.Stamp = .init() }
        func f() -> T { T() }
        """))
    }
}
