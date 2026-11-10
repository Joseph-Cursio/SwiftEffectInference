import Testing

/// The second adversarial round against `ConstructionFacts`: holes in the revision that resolved a
/// name by which candidate's initializer fit the call. Every refutation was confirmed at runtime
/// first — two calls with the same input gave different results, or the code was seen running.
@Suite("Construction purity: the second probe round")
struct ConstructionPurityRoundTwoTests: ConstructionTesting {

    // MARK: - The lexically meant namesake is never dropped

    @Test("the namesake Swift resolves is a candidate, whatever initializer it has", arguments: [
        // A nested class whose init() is implicit, from an extension of its enclosing type.
        """
        struct Item { var name = "" }
        enum Store { final class Item { let id = UUID() } }
        extension Store { static func make() -> Item { Item() } }
        """,
        // From a sibling nested type.
        """
        struct Item { var name = "" }
        enum Cache {
            final class Item { let id = UUID() }
            struct Builder { func make() -> Item { Item() } }
        }
        """,
        // Two declarations of one name in `#if` branches.
        """
        #if os(Linux)
        struct Stamp { var n = 0 }
        #else
        final class Stamp { let id = UUID() }
        #endif
        func make() -> Stamp { Stamp() }
        """,
        // A nested type declared in an extension, and a namesake nested elsewhere.
        """
        struct ContentView {}
        extension ContentView { final class ViewModel { let sessionID = UUID() } }
        struct SettingsView { struct ViewModel { var n = 0 } }
        extension ContentView { func make() -> ViewModel { ViewModel() } }
        """,
        // An actor's implicit init().
        """
        struct Counter { var n = 0 }
        enum Engine { actor Counter { var started = ContinuousClock.now } }
        extension Engine { static func make() -> Counter { Counter() } }
        """,
        // A superclass outside the package.
        """
        struct Coordinator { var n = 0 }
        enum Flow { final class Coordinator: NSObject { let sessionID = UUID() } }
        extension Flow { static func make() -> Coordinator { Coordinator() } }
        """,
        // A local typealias.
        """
        struct DirtyBox { let id = UUID() }
        struct Item { var n = 0 }
        func make() -> Any { typealias Item = DirtyBox; return Item() }
        """,
        // A qualified spelling from an extension.
        """
        enum API { struct Request { let id = UUID() } }
        enum Other { enum API { struct Request { var n = 0 } } }
        struct Client {}
        extension Client { func make() -> Any { API.Request() } }
        """,
        // A subclass with only a convenience initializer inherits the designated ones.
        """
        class Base { let name: String; init(name: String) { self.name = name } }
        enum Auth { final class Session: Base { let id = UUID(); convenience init() { self.init(name: "") } } }
        struct Session { var name: String }
        extension Auth { static func make(_ n: String) -> Session { Session(name: n) } }
        """,
        // The same, matched only by the shape of a contextless `.init(name:)`.
        """
        class Base { let name: String; init(name: String) { self.name = name } }
        enum Auth { final class Session: Base { let id = UUID(); convenience init() { self.init(name: "") } } }
        func use(_ s: Auth.Session) {}
        func make(_ n: String) { use(.init(name: n)) }
        """,
    ])
    func lexicallyMeantNamesake(source: String) throws {
        #expect(try constructionRefuted("make", in: source), "\(source)")
    }

    @Test("Self covers the conformers and subclasses that rely on an implicit or inherited init")
    func selfThroughImplicitInitializers() throws {
        #expect(try constructionRefuted("reset", in: """
        protocol Resettable { init() }
        extension Resettable { func reset() -> Self { Self() } }
        struct Form: Resettable { var text = "" }
        final class Session: Resettable { let id = UUID() }
        """))
        #expect(try constructionRefuted("clone", in: """
        class Base { required init() {}; func clone() -> Self { Self() } }
        final class Child: Base { let id = UUID(); convenience init(tag: Int) { self.init() } }
        """))
    }

    // MARK: - Inherited initializers

    @Test("an own initializer sharing labels with an inherited one does not hide it")
    func inheritedOverloadByType() throws {
        let source = """
        class Base { let at: Double; init(value: Int) { at = Date().timeIntervalSince1970 + Double(value) } }
        final class Sub: Base {
            convenience init(value: String) { self.init(value: Int(value) ?? 0) }
        }
        func direct(_ v: Int) -> Sub { Sub(value: v) }
        func viaConvenience(_ s: String) -> Sub { Sub(value: s) }
        """
        #expect(try constructionRefuted("direct", in: source))
        #expect(try constructionRefuted("viaConvenience", in: source))
    }

    @Test("the implicit super.init() reaches an init the superclass inherited")
    func implicitSuperThroughInheritedInit() throws {
        #expect(try constructionRefuted("f", in: """
        class Grand { let at: Double; init() { at = Date().timeIntervalSince1970 } }
        class Base: Grand { var name = "" }
        final class Sub: Base { let n: Int; init(n: Int) { self.n = n } }
        func f(_ n: Int) -> Sub { Sub(n: n) }
        """))
    }

    @Test("references and decodes follow inherited initializers")
    func referencesAndDecodesInherit() throws {
        let references = """
        class Base { let at: Double; init(v: Int) { at = Date().timeIntervalSince1970 + Double(v) } }
        final class Sub: Base {}
        func f(_ xs: [Int]) -> [Sub] { xs.map(Sub.init(v:)) }
        func g(_ xs: [Int]) -> [Sub] { xs.map(Sub.init) }
        """
        #expect(try constructionRefuted("f", in: references))
        #expect(try constructionRefuted("g", in: references))
        #expect(try constructionRefuted("parse", in: """
        class B2: Decodable {
            let at: Double
            required init(from decoder: Decoder) throws { at = Date().timeIntervalSince1970 }
        }
        final class S2: B2 {}
        func parse(_ d: Data) -> S2? { try? JSONDecoder().decode(S2.self, from: d) }
        """))
    }

    // MARK: - Decoding

    @Test("a decode constructs the elements of a container and the types its properties hold")
    func decodingContainersAndProperties() throws {
        let source = """
        struct Item: Decodable, Identifiable {
            let id = UUID(); let name: String
            enum CodingKeys: String, CodingKey { case name }
        }
        struct Feed: Decodable { let items: [Item] }
        struct Wrapper: Decodable {
            let item: Item?
            enum CodingKeys: String, CodingKey { case item }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                item = try c.decodeIfPresent(Item.self, forKey: .item)
            }
        }
        func parse(_ d: Data) -> Feed? { try? JSONDecoder().decode(Feed.self, from: d) }
        func parseList(_ d: Data) -> [Item]? { try? JSONDecoder().decode([Item].self, from: d) }
        func parseDict(_ d: Data) -> [String: Item]? { try? JSONDecoder().decode([String: Item].self, from: d) }
        func parseWrapper(_ d: Data) -> Wrapper? { try? JSONDecoder().decode(Wrapper.self, from: d) }
        """
        for name in ["parse", "parseList", "parseDict", "parseWrapper"] {
            #expect(try constructionRefuted(name, in: source), "\(name)")
        }
    }

    @Test("a decode is judged by every init(from:) the type has, whatever order the files come in")
    func everyDecodingInitializer() throws {
        let linux = """
        struct Event: Decodable { let at: Double }
        #if os(Linux)
        extension Event { init(from decoder: Decoder) throws { at = 0 } }
        #endif
        func parse(_ d: Data) -> Event? { try? JSONDecoder().decode(Event.self, from: d) }
        """
        let apple = """
        #if !os(Linux)
        extension Event { init(from decoder: Decoder) throws { at = Date().timeIntervalSince1970 } }
        #endif
        """
        for sources in [[linux, apple], [apple, linux]] {
            #expect(try constructionRefutation(of: "parse", in: sources) != nil, "\(sources)")
        }
    }

    // MARK: - Protocol-extension initializers

    @Test("a protocol-extension initializer reaches every conformer, however it conforms", arguments: [
        // Refined through a where clause.
        """
        protocol Seedable { init() }
        protocol Fancy where Self: Seedable {}
        extension Seedable { init(seed: Int) { self.init(); print("seeded \\(seed)") } }
        struct Token: Fancy { var n = 0 }
        func f() -> Token { Token(seed: 1) }
        """,
        // Refined through a composition.
        """
        protocol Seedable { init() }
        protocol Named {}
        protocol Fancy: Seedable & Named {}
        extension Seedable { init(seed: Int) { self.init(); print("seeded \\(seed)") } }
        struct Token: Fancy { var n = 0 }
        func f() -> Token { Token(seed: 1) }
        """,
        // A composition through a typealias.
        """
        protocol Seedable { init() }
        protocol Named {}
        typealias Entity = Seedable & Named
        extension Seedable { init(seed: Int) { self.init(); print("seeded \\(seed)") } }
        struct Token: Entity { var n = 0 }
        func f() -> Token { Token(seed: 1) }
        """,
        // A composition written in place.
        """
        protocol Seedable { init() }
        protocol Named {}
        extension Seedable { init(seed: Int) { self.init(); print("seeded \\(seed)") } }
        struct Token: Seedable & Named { var n = 0 }
        func f() -> Token { Token(seed: 1) }
        """,
        // An enum with a raw type is RawRepresentable without saying so.
        """
        extension RawRepresentable where RawValue == String {
            init?(randomFrom o: [String]) { self.init(rawValue: o.randomElement() ?? "") }
        }
        enum Color: String { case red, blue }
        func f(_ o: [String]) -> Color? { Color(randomFrom: o) }
        """,
        // A protocol sharing its name with a nested struct.
        """
        protocol Model { init() }
        enum Store { struct Model { var n = 0 } }
        extension Model { init(seed: Int) { self.init(); print("seeded") } }
        struct User: Model { var name = "" }
        func f() -> User { User(seed: 1) }
        """,
    ])
    func protocolExtensionInitializerConformers(source: String) throws {
        #expect(try constructionRefuted("f", in: source), "\(source)")
    }

    @Test("self.init delegation survives an extension of a typealias and a protocol namesake")
    func delegationThroughAliasAndNamesake() throws {
        #expect(try constructionRefuted("f", in: """
        struct Box { var at: Double; init() { at = Date().timeIntervalSince1970 }; init(at: Double) { self.at = at } }
        typealias Crate = Box
        extension Crate { init(seeded: Int) { self.init() } }
        func f() -> Box { Box(seeded: 1) }
        """))
        #expect(try constructionRefuted("g", in: """
        protocol Item {}
        enum Cart {
            struct Item { var at: Double; init() { at = Date().timeIntervalSince1970 }; init(x: Int) { self.init() } }
        }
        func g() -> Cart.Item { Cart.Item(x: 1) }
        """))
    }
}
