import Testing
@testable import SwiftEffectInference

/// The second adversarial round against `ConstructionFacts`: holes in the revision that resolved a
/// name by which candidate's initializer fit the call. Every refutation was confirmed at runtime
/// first — two calls with the same input gave different results, or the code was seen running.
@Suite("Construction purity: the second probe round")
struct ConstructionPurityRoundTwoTests {

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
        """
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
        """
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

extension ConstructionPurityRoundTwoTests {

    // MARK: - Assignment context

    @Test("an assignment to a local that shadows a stored property is not typed by the property")
    func assignmentToShadowingLocal() throws {
        let source = """
        struct Clean { var title = "" }
        struct Dirty { let id = UUID(); var title = "" }
        struct Holder {
            var item: Clean
            func f(_ seed: Dirty) -> Dirty { var item = seed; item = .init(title: "x"); return item }
            func g(_ seeds: [Dirty]) -> [Dirty] {
                var out: [Dirty] = []
                for var item in seeds { item = .init(title: item.title); out.append(item) }
                return out
            }
            func h(_ item: inout Dirty) { item = .init(title: "x") }
        }
        """
        for name in ["f", "g", "h"] {
            #expect(try constructionRefuted(name, in: source), "\(name)")
        }
    }

    @Test("two declarations of one name keep their own stored-property types, in either order")
    func memberTypesPerDeclaration() throws {
        let clean = """
        struct Clean { var title: String }
        struct Holder { var item: Clean
            mutating func resetA() { item = .init(title: "x") } }
        """
        let minted = """
        struct Minted { let id = UUID(); var title: String }
        struct Holder { var item: Minted
            mutating func resetB() { item = .init(title: "y") } }
        """
        for sources in [[clean, minted], [minted, clean]] {
            #expect(try constructionRefutation(of: "resetA", in: sources) == nil)
            #expect(try constructionRefutation(of: "resetB", in: sources) != nil)
        }
    }

    // MARK: - Implicit members

    @Test("an implicit member nested in a default, or behind a typealias, is judged", arguments: [
        "struct T { var stamps: [Date] = [.now]; let note: String }\nfunc f(_ n: String) -> T { T(note: n) }",
        "struct T { let ids: [UUID] = [.init(), .init()]; let n: Int }\nfunc f(_ n: Int) -> T { T(n: n) }",
        "struct T { let ids: Set<UUID> = [.init()]; let n: Int }\nfunc f(_ n: Int) -> T { T(n: n) }",
        "struct T { var at: (Date, Int) = (.now, 0); let n: Int }\nfunc f(_ n: Int) -> T { T(n: n) }",
        "typealias Timestamp = Date\nstruct T { var at: Timestamp = .now; let n: Int }\nfunc f(_ n: Int) -> T { T(n: n) }",
        "typealias Instant = ContinuousClock.Instant\nfinal class T { var start: Instant = .now; init() {} }\nfunc f() -> T { T() }",
        "typealias Timestamp = Date\nstruct T { let at: Timestamp; init(at: Timestamp = .now) { self.at = at } }\nfunc f() -> T { T() }",
        "struct T { let stamps: [Date]; init(stamps: [Date] = [.now]) { self.stamps = stamps } }\nfunc f() -> T { T() }"
    ])
    func nestedImplicitMembers(source: String) throws {
        #expect(try constructionRefuted("f", in: source), "\(source)")
    }

    @Test("an implicit member inside a closure default is not the annotation's")
    func implicitMemberInClosureDefault() throws {
        // Measured on SwiftMarkdownWiki: `.withInternetDateTime` was judged as `Date.withInternetDateTime`.
        #expect(try !constructionRefuted("f", in: """
        struct Config {
            var message: @Sendable (Date) -> String = { date in
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                return formatter.string(from: date)
            }
        }
        func f() -> Config { Config() }
        """))
    }

    // MARK: - Other constructions

    @Test("a property wrapper on a local variable constructs the wrapper")
    func localPropertyWrapper() throws {
        #expect(try constructionRefuted("f", in: """
        @propertyWrapper struct Stamped { let at = Date(); var wrappedValue: Int }
        func f() -> Double { @Stamped var x = 1; return _x.at.timeIntervalSince1970 + Double(x) }
        """))
    }

    @Test("a qualified spelling whose head is a typealias or a module resolves through it")
    func aliasOrModuleHead() throws {
        #expect(try constructionRefuted("make", in: """
        enum Outer { struct Bar { let id = UUID(); var n = 0 } }
        typealias Foo = Outer
        enum Other { enum Foo { struct Bar { var n = 0 } } }
        func make() -> Any { Foo.Bar() }
        """))
        let billing = "public struct Invoice { public let id = UUID(); public init() {} }"
        let app = """
        enum Reports { enum Billing { struct Invoice { var n = 0 } } }
        func issue() -> Any { Billing.Invoice() }
        """
        #expect(try constructionRefutation(of: "issue", in: [billing, app]) != nil)
    }

    @Test("a labelled tuple element binds by label, not by position")
    func tupleShuffle() throws {
        #expect(try constructionRefuted("f", in: """
        struct Clean { var title = "" }
        struct Dirty { let id = UUID(); var title = "" }
        func f() -> (a: Clean, b: Dirty) { (b: .init(title: "x"), a: Clean()) }
        """))
    }

    @Test("T.self.init(…) constructs T")
    func metatypeSelfInit() throws {
        #expect(try constructionRefuted("f", in: """
        struct Dirty { let id = UUID(); var title = "" }
        func f() -> Dirty { Dirty.self.init(title: "x") }
        """))
    }

    // MARK: - Precision: what must stay pure

    @Test("a class inherits only from a class: a protocol or SDK superclass namesake is not charged")
    func superclassMustBeAClass() throws {
        #expect(try !constructionRefuted("open", in: """
        protocol Item { var title: String { get } }
        enum Menu { struct Item: Identifiable { let id = UUID(); var title: String } }
        final class Document: Item { let title: String; init(title: String) { self.title = title } }
        func open(_ t: String) -> Document { Document(title: t) }
        """))
        #expect(try !constructionRefuted("makeUpload", in: """
        enum Sync { struct Operation: Identifiable { let id = UUID(); var path: String = "" } }
        final class UploadOperation: Operation, @unchecked Sendable {
            let path: String
            init(path: String) { self.path = path }
            override func main() {}
        }
        func makeUpload(_ p: String) -> UploadOperation { UploadOperation(path: p) }
        """))
    }

    @Test("a generic parameter shadows only where it is in scope")
    func genericParameterScope() throws {
        #expect(try !constructionRefuted("initial", in: """
        struct Box<State> { var value: State }
        enum Login { struct State { let id = UUID(); var user = "" } }
        enum Counter {
            struct State { var count = 0 }
            static func initial() -> State { State() }
        }
        """))
    }

    @Test("a type nested elsewhere is not a candidate for a top-level spelling", arguments: [
        """
        enum Settings { struct Section: Identifiable { let id = UUID(); var title: String } }
        func f() -> some View { Section("General") { Text("x") } }
        """,
        """
        enum Palette { struct Color: Identifiable { let id = UUID(); let name: String } }
        func f() -> SwiftUI.Color { Color(red: 1, green: 0, blue: 0) }
        """,
        """
        enum Project { struct Task: Identifiable { let id = UUID(); var title: String } }
        func f(_ x: Int) -> Int { _ = Task { x * 2 }; return x }
        """
    ])
    func nestedNamesakeOutOfReach(source: String) throws {
        #expect(try !constructionRefuted("f", in: source), "\(source)")
    }

    @Test("a type local to a function is out of reach from a stored member of another type")
    func localTypeOutOfReach() throws {
        #expect(try !constructionRefuted("make", in: """
        struct Row { var title: String }
        func decode(_ d: Data) -> Int {
            struct Row: Decodable { let id = UUID(); var title: String }
            return 0
        }
        struct Table { func make(_ t: String) -> Row { Row(title: t) } }
        """))
    }

    @Test("a type's own initializer is preferred to a protocol extension's with the same labels")
    func ownInitializerOverProtocolDefault() throws {
        #expect(try !constructionRefuted("zero", in: """
        protocol Stampable { var stamp: Double { get }; init(stamp: Double) }
        extension Stampable { init() { print("default ran"); self.init(stamp: Date().timeIntervalSince1970) } }
        struct Fixed: Stampable { let stamp: Double; init(stamp: Double) { self.stamp = stamp }; init() { stamp = 0 } }
        func zero() -> Fixed { Fixed() }
        """))
    }

    @Test("a @StateObject initial value is an autoclosure, not run on construction")
    func stateObjectIsDeferred() throws {
        #expect(try !constructionRefuted("makeRoot", in: """
        final class Store: ObservableObject { let defaults = UserDefaults.standard; init() { print("Store.init ran") } }
        struct RootView: View { @StateObject private var store = Store(); var body: some View { EmptyView() } }
        func makeRoot() -> RootView { RootView() }
        """))
    }

    @Test("an unlabelled defaulted parameter the call supplies is not omitted")
    func suppliedUnlabelledDefault() throws {
        #expect(try !constructionRefuted("fixed", in: """
        struct Stamp { let label: String; let at: Date
            init(_ label: String, _ at: Date = Date()) { self.label = label; self.at = at } }
        func fixed(_ l: String, _ d: Date) -> Stamp { Stamp(l, d) }
        """))
    }

    // MARK: - Accepted over-refutation, pinned

    /// The cost of "any doubt refutes", documented on `ConstructionFacts`: a contextless labelled
    /// `.init(…)` that an SDK type takes is matched against a package type that takes it too, and a
    /// module prefix naming an SDK type is dropped when it names nothing in the package. Pinned so
    /// that a change to either is a decision, not an accident.
    @Test("known over-refutations", arguments: [
        """
        struct DataPoint: Identifiable { let id = UUID(); let x: Double; let y: Double }
        func f(in rect: CGRect) -> Path { var path = Path(); path.move(to: .init(x: rect.minX, y: rect.maxY)); return path }
        """,
        """
        struct DataPoint: Identifiable { let id = UUID(); var x: Double; var y: Double }
        struct Chart {
            var point: DataPoint
            func f(_ x: Double) -> CGPoint { var point = CGPoint.zero; point = .init(x: x, y: 0); return point }
        }
        """,
        """
        struct Section: Identifiable { let id = UUID(); var title: String }
        func f(_ t: String) -> some View { SwiftUI.Section(t) { Text(t) } }
        """
    ])
    func knownOverRefutations(source: String) throws {
        #expect(try constructionRefuted("f", in: source), "\(source)")
    }
}
