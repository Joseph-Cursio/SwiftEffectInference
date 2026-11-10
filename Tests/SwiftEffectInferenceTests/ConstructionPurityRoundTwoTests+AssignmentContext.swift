@testable import SwiftEffectInference
import Testing

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
        "struct T { let stamps: [Date]; init(stamps: [Date] = [.now]) { self.stamps = stamps } }\nfunc f() -> T { T() }",
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
        """,
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
        """,
    ])
    func knownOverRefutations(source: String) throws {
        #expect(try constructionRefuted("f", in: source), "\(source)")
    }
}
