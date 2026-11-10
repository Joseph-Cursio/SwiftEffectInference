@testable import SwiftEffectInference
import Testing

/// The holes an adversarial review of `ConstructionFacts` found before it shipped — each a
/// construction that runs a clock, an identity or a side effect and was still judged pure, or a
/// pure function judged otherwise — one test per shape, and the known misses pinned.
///
/// Every refutation here was confirmed at runtime first: the snippet compiled with `swiftc` and the
/// code it claims runs was seen running.
@Suite("Construction purity: the probed holes")
struct ConstructionPurityProbeTests: ConstructionTesting {

    func refutation(of name: String, in source: String) throws -> PurityRefutation? {
        try constructionRefutation(of: name, in: [source])
    }

    func refuted(_ name: String, in source: String) throws -> Bool {
        try constructionRefuted(name, in: source)
    }

    // MARK: - Defaults that name their type only in the annotation

    @Test("an implicit-member default is judged against its annotation", arguments: [
        "struct T { var created: Date = .now; let text: String }\nfunc f(_ t: String) -> T { T(text: t) }",
        "struct T { let id: UUID = .init(); let text: String }\nfunc f(_ t: String) -> T { T(text: t) }",
        "struct T { var locale: Locale = .current; let n: Int }\nfunc f(_ n: Int) -> T { T(n: n) }",
        "final class T { var started: Date = .init(); init() {} }\nfunc f() -> T { T() }",
        "actor T { private var last: ContinuousClock.Instant = .now; init() {} }\nfunc f() -> T { T() }",
        "struct T { let at: Date; init(at: Date = .now) { self.at = at } }\nfunc f() -> T { T() }",
    ])
    func implicitMemberDefaults(source: String) throws {
        #expect(try refuted("f", in: source), "\(source)")
    }

    // MARK: - Names

    @Test("a type local to one method does not hide the real one from another")
    func localTypeDoesNotShadowOtherMethods() throws {
        #expect(try refuted("make", in: """
        struct Entry { let id = UUID(); let title: String }
        struct Journal {
            func decodeLegacy(_ s: String) -> Int {
                struct Entry { let title: String }
                return Entry(title: s).title.count
            }
            func make(_ t: String) -> Entry { Entry(title: t) }
        }
        """))
    }

    @Test("a qualified spelling resolves its head from where it is written")
    func qualifiedSpellingIsLexical() throws {
        #expect(try refuted("make", in: """
        enum API { struct Request { let path: String } }
        struct Client {
            enum API { struct Request { let id = UUID(); let path: String } }
            func make(_ p: String) -> Any { API.Request(path: p) }
        }
        """))
    }

    /// Swift resolves a local typealias before a member type of the enclosing declaration, so a
    /// name a function body can rebind is never resolved with certainty.
    @Test("a local typealias can shadow a member type, so the name is not certain")
    func localTypealiasShadows() throws {
        #expect(try refuted("build", in: """
        struct Dirty { let id = UUID(); init() {} }
        struct Outer {
            struct Item { init() {} }
            func build() -> Any { typealias Item = Dirty; return Item() }
        }
        """))
    }

    @Test("a declaration duplicated across #if branches is consulted in full")
    func duplicatedDeclarationIsAUnion() throws {
        #expect(try refuted("f", in: """
        #if os(macOS)
        struct Stamp { let title: String }
        #else
        struct Stamp { let id = UUID(); let title: String }
        #endif
        func f(_ t: String) -> Stamp { Stamp(title: t) }
        """))
    }

    @Test("members inside #if are seen")
    func ifConfigMembersAreSeen() throws {
        #expect(try refuted("f", in: """
        struct Stamp {
            let title: String
            #if DEBUG
            let traced = Date()
            #endif
        }
        func f(_ t: String) -> Stamp { Stamp(title: t) }
        """))
    }

    @Test("a module-qualified and an underscored spelling both resolve", arguments: [
        "struct _Token { let id = UUID() }\nfunc f() -> Any { _Token() }",
        "struct Token { let id = UUID() }\nfunc f() -> Any { MyModule.Token() }",
    ])
    func unusualSpellingsResolve(source: String) throws {
        #expect(try refuted("f", in: source))
    }

    @Test("a typealias chain reaches its target")
    func typealiasChain() throws {
        #expect(try refuted("f", in: """
        struct Stamp { let id = UUID() }
        typealias A = Stamp
        typealias B = A
        typealias C = B
        typealias D = C
        func f() -> Any { D() }
        """))
    }

    // MARK: - Initializers that do not show their work

    @Test("a protocol extension's initializer belongs to every conformer")
    func protocolExtensionInitializer() throws {
        #expect(try refuted("newUser", in: """
        protocol Entity { init(id: UUID, name: String) }
        extension Entity { init(name: String) { self.init(id: UUID(), name: name) } }
        struct User: Entity { let id: UUID; let name: String }
        func newUser(_ name: String) -> User { User(name: name) }
        """))
    }

    @Test("a trailing closure is bound by forward scan", arguments: [
        "struct Command { let run: () -> Void; var id = UUID() }\nfunc f() -> Command { Command { } }",
        """
        struct Button {
            let title: String; let action: () -> Void; let createdAt: Date
            init(_ title: String, action: @escaping () -> Void, createdAt: Date = Date()) {
                self.title = title; self.action = action; self.createdAt = createdAt
            }
        }
        func f(_ t: String) -> Button { Button(t) { } }
        """,
    ])
    func trailingClosureForwardScan(source: String) throws {
        #expect(try refuted("f", in: source))
    }

    @Test("a memberwise call through an implicitly unwrapped, a lazy or a protocol initializer", arguments: [
        "struct Draft { var id = UUID(); var title: String! }\nfunc f() -> Draft { Draft() }",
        "struct Cached { var id = UUID(); lazy var cache: Int = 0 }\nfunc f(_ c: Int) -> Cached { Cached(cache: c) }",
        """
        protocol Seedable { init() }
        extension Seedable { init(seed: Int) { self.init() } }
        struct Token: Seedable { var id = UUID() }
        func f(_ s: Int) -> Token { Token(seed: s) }
        """,
    ])
    func memberwiseShapes(source: String) throws {
        #expect(try refuted("f", in: source))
    }

    @Test("a designated initializer without super.init still calls super.init()")
    func implicitSuperInitializer() throws {
        #expect(try refuted("f", in: """
        class Base { let at: Date; init() { at = Date() } }
        final class Sub: Base { let n: Int; init(n: Int) { self.n = n } }
        func f(_ n: Int) -> Sub { Sub(n: n) }
        """))
    }

    @Test("an inherited convenience initializer dispatches to the subclass's override")
    func inheritedConvenienceDispatchesToOverride() throws {
        #expect(try refuted("f", in: """
        class Base { let v: Int; init(value: Int) { v = value }; convenience init() { self.init(value: 0) } }
        class Derived: Base {
            let stamp: Double
            override init(value: Int) { stamp = Date().timeIntervalSince1970; super.init(value: value) }
        }
        func f() -> Derived { Derived() }
        """))
    }

    @Test("Self covers every conformer in a protocol extension, and every subclass of a non-final class")
    func dynamicSelf() throws {
        #expect(try refuted("reset", in: """
        protocol Resettable { init() }
        extension Resettable { func reset() -> Self { Self() } }
        struct Form: Resettable { let id = UUID(); var text = "" }
        """))
        #expect(try refuted("clone", in: """
        class Base { required init() {}; func clone() -> Self { Self() } }
        final class Child: Base { let id = UUID() }
        """))
    }

    @Test("an enum's initializer is judged")
    func enumInitializer() throws {
        #expect(try refuted("f", in: """
        enum Flavor { case a, b; init(seeded: Int) { self = Bool.random() ? .a : .b } }
        func f(_ s: Int) -> Flavor { Flavor(seeded: s) }
        """))
    }

    @Test("an extension initializer on a specialized or aliased spelling is attached", arguments: [
        "struct Box<T> { let v: T }\nextension Box<Int> { init(stamped: Int) { v = Int(Date().timeIntervalSince1970) } }\nfunc f() -> Any { Box<Int>(stamped: 1) }",
        "struct Box { let v: Int }\ntypealias Crate = Box\nextension Crate { init(stamped: Int) { v = Int(Date().timeIntervalSince1970) } }\nfunc f() -> Any { Box(stamped: 1) }",
    ])
    func extensionThroughSpecializationOrAlias(source: String) throws {
        #expect(try refuted("f", in: source))
    }

    @Test("a long delegation chain is followed to its end")
    func longDelegationChain() throws {
        #expect(try refuted("f", in: """
        struct Chain {
            let at: Double
            init(a: Int) { self.init(b: a) }
            init(b: Int) { self.init(c: b) }
            init(c: Int) { self.init(d: c) }
            init(d: Int) { self.init(e: d) }
            init(e: Int) { self.init(g: e) }
            init(g: Int) { at = Date().timeIntervalSince1970 }
        }
        func f() -> Chain { Chain(a: 1) }
        """))
    }
}
