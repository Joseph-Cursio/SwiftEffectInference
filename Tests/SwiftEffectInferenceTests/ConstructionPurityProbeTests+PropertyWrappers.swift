@testable import SwiftEffectInference
import Testing

extension ConstructionPurityProbeTests {

    // MARK: - Property wrappers and decoding

    @Test("a property wrapper declared in the package is constructed with its owner", arguments: [
        "@propertyWrapper struct Logged { var wrappedValue: Int; init(wrappedValue: Int) { print(\"set\"); self.wrappedValue = wrappedValue } }\nstruct Counter { @Logged var count = 0 }\nfunc f() -> Counter { Counter() }",
        "@propertyWrapper struct Stamped<V> { let at = Date(); var wrappedValue: V }\nstruct Model { @Stamped var x = 1 }\nfunc f() -> Model { Model() }",
        "@propertyWrapper struct Now { var wrappedValue = UUID() }\nstruct Holder { @Now var id: UUID; let name: String }\nfunc f(_ n: String) -> Holder { Holder(name: n) }",
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
        "func f(_ r: Item = .init(title: \"x\")) -> String { r.title }",
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
        "class { func make() -> Int { let s = Self(); return 0 } }\nfunc f() -> Int { 0 }",
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
        "import SwiftUI\nstruct V { @AppStorage(\"k\") var n = 0 }\nfunc f() -> V { V() }",
    ])
    func knownMisses(source: String) throws {
        #expect(try refuted("f", in: source) == false)
    }
}
