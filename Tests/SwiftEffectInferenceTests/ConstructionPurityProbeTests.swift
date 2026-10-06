import Testing
@testable import SwiftEffectInference

/// The holes an adversarial review of `ConstructionFacts` found before it shipped — each a
/// construction that runs a clock, an identity or a side effect and was still judged pure, or a
/// pure function judged otherwise — one test per shape, and the known misses pinned.
///
/// Every refutation here was confirmed at runtime first: the snippet compiled with `swiftc` and the
/// code it claims runs was seen running.
@Suite("Construction purity: the probed holes")
struct ConstructionPurityProbeTests {

    private func refutation(of name: String, in source: String) throws -> PurityRefutation? {
        try constructionRefutation(of: name, in: [source])
    }

    private func refuted(_ name: String, in source: String) throws -> Bool {
        try constructionRefuted(name, in: source)
    }

    // MARK: - Defaults that name their type only in the annotation

    @Test("an implicit-member default is judged against its annotation", arguments: [
        "struct T { var created: Date = .now; let text: String }\nfunc f(_ t: String) -> T { T(text: t) }",
        "struct T { let id: UUID = .init(); let text: String }\nfunc f(_ t: String) -> T { T(text: t) }",
        "struct T { var locale: Locale = .current; let n: Int }\nfunc f(_ n: Int) -> T { T(n: n) }",
        "final class T { var started: Date = .init(); init() {} }\nfunc f() -> T { T() }",
        "actor T { private var last: ContinuousClock.Instant = .now; init() {} }\nfunc f() -> T { T() }",
        "struct T { let at: Date; init(at: Date = .now) { self.at = at } }\nfunc f() -> T { T() }"
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
        "struct Token { let id = UUID() }\nfunc f() -> Any { MyModule.Token() }"
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
        """
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
        """
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
        "struct Box { let v: Int }\ntypealias Crate = Box\nextension Crate { init(stamped: Int) { v = Int(Date().timeIntervalSince1970) } }\nfunc f() -> Any { Box(stamped: 1) }"
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

extension ConstructionPurityProbeTests {

    // MARK: - Property wrappers and decoding

    @Test("a property wrapper declared in the package is constructed with its owner", arguments: [
        "@propertyWrapper struct Logged { var wrappedValue: Int; init(wrappedValue: Int) { print(\"set\"); self.wrappedValue = wrappedValue } }\nstruct Counter { @Logged var count = 0 }\nfunc f() -> Counter { Counter() }",
        "@propertyWrapper struct Stamped<V> { let at = Date(); var wrappedValue: V }\nstruct Model { @Stamped var x = 1 }\nfunc f() -> Model { Model() }",
        "@propertyWrapper struct Now { var wrappedValue = UUID() }\nstruct Holder { @Now var id: UUID; let name: String }\nfunc f(_ n: String) -> Holder { Holder(name: n) }"
    ])
    func propertyWrapperConstruction(source: String) throws {
        #expect(try refuted("f", in: source))
    }

    /// A global actor is an attribute too, and constructing a type isolated to one runs nothing.
    @Test("an attribute that is not a property wrapper constructs nothing")
    func globalActorAttributeIsNotAWrapper() throws {
        #expect(try refuted("f", in: """
        @globalActor actor Isolation { static let shared = Isolation(); let id = UUID() }
        struct Model { @Isolation var x = 1 }
        func f() -> Model { Model() }
        """) == false)
    }

    @Test("decoding a type builds it through init(from:)")
    func decodingConstructs() throws {
        #expect(try refuted("f", in: """
        struct Event: Decodable { let id = UUID(); let name: String }
        func f(_ data: Data) -> Any { try? JSONDecoder().decode(Event.self, from: data) as Any }
        """))
    }

    // MARK: - A base-less .init, anywhere the syntax types it

    @Test("a base-less .init takes its type from more contexts", arguments: [
        "struct Holder { var item: Item; mutating func f() { item = .init(title: \"x\") } }",
        "func f(_ c: Bool) -> Item { c ? .init(title: \"a\") : .init(title: \"b\") }",
        "func f(_ x: Item?) -> Item { x ?? .init(title: \"a\") }",
        "func f() -> [String: Item] { [\"a\": .init(title: \"x\")] }",
        "func f() -> (Item, Int) { (.init(title: \"x\"), 1) }",
        "func f(_ c: Bool) -> String { let item: Item = if c { .init(title: \"a\") } else { .init(title: \"b\") }; return item.title }",
        "func f(_ r: Item = .init(title: \"x\")) -> String { r.title }"
    ])
    func contextualInitializerPositions(function: String) throws {
        #expect(try refuted("f", in: "struct Item { let id = UUID(); var title = \"\" }\n" + function), "\(function)")
    }

    @Test("self = .init(…) in an initializer constructs Self")
    func selfAssignment() throws {
        #expect(try refuted("f", in: """
        struct Plain {
            var stamp: Date
            init(title: String) { stamp = Date() }
            init(x: Int) { self = .init(title: "") }
        }
        func f() -> Plain { Plain(x: 1) }
        """))
    }

    // MARK: - Precision

    @Test("a written defaulted label is not omitted, however the type is spelled")
    func specializedGenericKeepsItsLabels() throws {
        #expect(try refuted("f", in: """
        struct Box<T> {
            let id: UUID; let value: T
            init(id: UUID = UUID(), value: T) { self.id = id; self.value = value }
        }
        func f(_ id: UUID, _ v: Int) -> Box<Int> { Box<Int>(id: id, value: v) }
        """) == false)
    }

    @Test("a function value T.init evaluates no default argument")
    func referenceOmitsNoDefault() throws {
        #expect(try refuted("tags", in: """
        struct Tag { let id: UUID; init(id: UUID = UUID()) { self.id = id } }
        func tags(_ ids: [UUID]) -> [Tag] { ids.map(Tag.init) }
        """) == false)
    }

    @Test("a compound name T.init(label:) reaches only that initializer")
    func compoundNameReference() throws {
        let source = """
        struct Rec { let id: UUID; init(id: UUID) { self.id = id }; init(seed: Int) { id = UUID() } }
        func recs(_ ids: [UUID]) -> [Rec] { ids.map(Rec.init(id:)) }
        func seeded(_ s: [Int]) -> [Rec] { s.map(Rec.init(seed:)) }
        """
        #expect(try refuted("recs", in: source) == false)
        #expect(try refuted("seeded", in: source))
    }

    /// Found in the corpus re-measurement: SwiftAssist's `.foregroundColor(.init(nsColor:))` was
    /// charged with a package type's `FileManager` default, though nothing in the package takes
    /// `nsColor:`.
    @Test("a contextless .init is matched only against types whose initializers take its arguments")
    func shapeGuessNeedsAFit() throws {
        #expect(try refuted("f", in: """
        struct Workspace { let fileManager = FileManager.default; let root: String }
        func paint(_ c: Any) -> Int { 0 }
        func f(_ c: Int) -> Int { paint(.init(nsColor: c)) }
        """) == false)
    }

    /// Found in the corpus re-measurement: SwiftInferProperties declares several `Inputs`, and one
    /// whose initializer cannot take `typeName:` was charged for a call that names another.
    @Test("a namesake that cannot take the arguments is not what the spelling meant")
    func namesakeThatCannotFitIsSkipped() throws {
        #expect(try refuted("make", in: """
        enum Triage {
            struct Inputs {
                let prompt: String; let now: Date
                init(prompt: String, now: Date = Date()) { self.prompt = prompt; self.now = now }
            }
        }
        enum Emitter {}
        extension Emitter {
            struct Inputs { let typeName: String }
            static func make(_ t: String) -> Inputs { Inputs(typeName: t) }
        }
        """) == false)
    }

    // MARK: - Robustness

    @Test("a recursive construction converges, with a shallow witness")
    func recursiveConstructionConverges() throws {
        let witness = try #require(try refutation(of: "parse", in: """
        struct Stamp { let id = UUID() }
        struct Node {
            let name: String
            let children: [Node]
            let stamp: Stamp
            init(dict: [String: Any]) {
                name = dict["name"] as? String ?? ""
                children = (dict["children"] as? [[String: Any]] ?? []).map { Node(dict: $0) }
                stamp = Stamp()
            }
        }
        func parse(_ d: [String: Any]) -> Node { Node(dict: d) }
        """))
        #expect(witness.description.count < 400, "witness grew: \(witness.description.count) characters")
    }

    @Test("a nameless declaration does not trap", arguments: [
        "extension { func copy() -> Int { _ = Self(); return 1 } }\nfunc f() -> Int { 0 }",
        "struct { let x: Int; init() { self.init(x: 1) }; init(x: Int) { self.x = x } }\nfunc f() -> Int { 0 }",
        "class { func make() -> Int { let s = Self(); return 0 } }\nfunc f() -> Int { 0 }"
    ])
    func namelessDeclarationDoesNotTrap(source: String) throws {
        _ = try refutation(of: "f", in: "struct Stamp { let id = UUID() }\n" + source)
    }

    // MARK: - Known misses, pinned

    /// Each of these constructs a refuted type and is judged pure. They are pinned so a change
    /// that closes one is noticed, and stated on `ConstructionFacts`.
    @Test("the known misses stay as documented", arguments: [
        // An enum case's associated-value default.
        "enum Event { case opened(at: Date = Date()) }\nfunc f() -> Event { .opened() }",
        // A literal conversion.
        "struct Tag: ExpressibleByStringLiteral { let id = UUID(); let text: String; init(stringLiteral v: String) { text = v } }\nfunc f() -> Tag { \"x\" }",
        // A generic parameter constructed.
        "protocol Makeable { init() }\nstruct Stamp2: Makeable { let id = UUID() }\nfunc f<T: Makeable>(_: T.Type) -> T { T() }",
        // A property wrapper the package does not declare.
        "import SwiftUI\nstruct V { @AppStorage(\"k\") var n = 0 }\nfunc f() -> V { V() }"
    ])
    func knownMisses(source: String) throws {
        #expect(try refuted("f", in: source) == false)
    }
}
