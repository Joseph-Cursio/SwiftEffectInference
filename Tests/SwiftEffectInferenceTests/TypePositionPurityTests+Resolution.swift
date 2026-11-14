@testable import SwiftEffectInference
import SwiftParser
import SwiftSyntax
import Testing

/// Every function declared with a given name, nested or not, in source order.
private final class NamedFunctions: SyntaxVisitor {
    private let name: String
    private(set) var found: [FunctionDeclSyntax] = []

    init(named name: String) {
        self.name = name
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == name { found.append(node) }
        return .visitChildren
    }
}

extension TypePositionPurityTests {

    // MARK: - Names Swift resolves past their spelling, and the gates that stay

    /// Each of these resolves differently in Swift than by spelling alone.
    @Test("a name Swift resolves elsewhere than its spelling suggests still refutes", arguments: [
        // An omitted default or a variadic lets an SDK overload of that arity win.
        """
        func getpid(_ x: Int = 0) -> String { "" }
        func f() -> Int32 { let d: [Date] = []; return getpid() + Int32(d.count) }
        """,
        """
        func getuid(_ xs: Int...) -> Bool { true }
        func f() -> UInt32 { let d: [Date] = []; return getuid() &+ UInt32(d.count) }
        """,
        // A declaration only in an `#if`, or bound by a tuple pattern, still shadows the vocabulary.
        """
        #if canImport(Darwin)
        typealias max = Date
        #endif
        func f() -> Double { let d: Date = max(); return d.timeIntervalSince1970 }
        """,
        """
        enum Env { static let (first, second): (() -> Date, Int) = (Date.init, 0) }
        func f() -> Double { let d: Date = Env.first(); return d.timeIntervalSince1970 }
        """,
        // An alias resolves to the innermost declaration of its target.
        """
        struct Now {}
        enum Clock { typealias Now = Date; typealias Stamp = Now }
        func f() -> Double { let d: Date = Clock.Stamp(); return d.timeIntervalSince1970 }
        """,
        // A wrapper spelled like an inert attribute is the package's code.
        """
        @propertyWrapper struct MainActor { var wrappedValue: UInt64;
            init(wrappedValue: UInt64, _ by: UInt64) { self.wrappedValue = by } }
        enum Boot { @MainActor(mach_approximate_time()) static var stamp: UInt64 = 0 }
        func f() -> UInt64 { let seen: [Date: Int] = [:]; return Boot.stamp &+ UInt64(seen.count) }
        """,
        // A package `~=` is called by a pattern with no token written.
        """
        func ~= (lhs: LocalizedStringResource, rhs: Int) -> Bool { true }
        func f(_ n: Int) -> Bool { let d: Date? = nil; _ = d; if case "Hi" = n { return true }; return false }
        """,
        // A rebound literal type makes every literal an SDK value.
        """
        typealias StringLiteralType = LocalizedStringResource
        func f() -> Int { let d: [Date: Int] = [:]; let s = "Hi"; _ = s; return d.count }
        """,
        // An implicit member chain's root is a static on the contextual type: `Date.timeIntervalSinceReferenceDate`.
        """
        struct R { var timeIntervalSinceReferenceDate: Double }
        extension Double { func asInstant() -> Date { Date(timeIntervalSinceReferenceDate: self) } }
        func f() -> Double { func g() -> Date { .timeIntervalSinceReferenceDate.asInstant() };
            return g().timeIntervalSince1970 }
        """,
        // `Self`, an enclosing generic type, and `self` in an SDK type's extension type a literal.
        "extension LocalizedStringResource { static func f() -> Self { let d: Date? = nil; _ = d; return \"Hi\" } }",
        "struct Greeter<T: ExpressibleByStringLiteral> { func f() -> T { let d: Date? = nil; _ = d; return \"Hi\" } }",
        "extension LocalizedStringResource { func f() -> Bool { let d: Date? = nil; _ = d; return self == \"Hi\" } }",
        // A nested function judged alone sees its outer function's local alias.
        """
        func outer(_ seed: UUID) -> Bool { typealias Substring = UUID; func f(_ id: UUID) -> Bool {
            let other: UUID = Substring(); return other == id }; return f(seed) }
        """,
    ])
    func resolvedElsewhere(source: String) throws {
        let finder = NamedFunctions(named: "f")
        finder.walk(Parser.parse(source: source))
        let function = try #require(finder.found.last)
        #expect(inferrer(for: source).verdict(for: function) == .refuted, "\(source)")
    }

    /// A function value, a default or a global that reaches the body without a name it could check.
    @Test("code the package hands over without a checkable name still refutes", arguments: [
        // A left-out method spelled like a vocabulary member, called in its shape.
        """
        struct S { func first() -> () -> Date { Date.init } }
        func f(_ s: S) -> Double { let d: Date = s.first()(); return d.timeIntervalSince1970 }
        """,
        // A vocabulary static is a constant: called, it can only be a package static.
        """
        extension Int { static func max(_ x: Int) -> () -> Date { Date.init } }
        func f() -> Double { let d: Date = Int.max(0)(); return d.timeIntervalSince1970 }
        """,
        // An `inout` function parameter is filled in by the package.
        """
        enum Source { static func install(_ slot: inout () -> Date) { slot = Date.init } }
        func f() -> Double { var make: () -> Date = { .distantPast }; Source.install(&make); let d: Date = make();
            return d.timeIntervalSince1970 }
        """,
        // A subscript's default argument runs in the caller, with no name to check.
        """
        struct Table { subscript(_ i: Int, at: Date = Date()) -> Date { at } }
        func f(_ t: Table) -> Double { let d: Date = t[0]; return d.timeIntervalSince1970 }
        """,
        // A global `var` holds whatever code last stored.
        "var zone = \"\"\nfunc f() -> String { let d: Date? = nil; _ = d; return zone }",
        // `#available` reads the running OS's version.
        "func f() -> Int { let d: [Date] = []; if #available(macOS 99, *) { return 1 + d.count }; return d.count }",
    ])
    func handedWithoutName(source: String) throws {
        let finder = NamedFunctions(named: "f")
        finder.walk(Parser.parse(source: source))
        let function = try #require(finder.found.last)
        #expect(inferrer(for: source).verdict(for: function) == .refuted, "\(source)")
    }

    /// Dispatch, rewriting and spelling that no name in the body shows.
    @Test("a call the body writes but something else answers still refutes", arguments: [
        // A member on `AnyObject` is an Objective-C selector, which `@objc(…)` can spell as an SDK one.
        """
        final class Clock: NSObject { @objc(timeIntervalSinceNow) func elapsed() -> Double { 0 } }
        func f(_ d: Date) -> Double { let held: Date = d; return (held as AnyObject).elapsed() }
        """,
        // A name written with its labels is a function, never the parameter it shadows.
        "func f(_ setlocale: Int) -> Int { let d: [Date] = []; let g = setlocale(_:_:); _ = g; return d.count }",
        // A result builder on a callee's parameter, or on a protocol requirement, rewrites the body.
        """
        @resultBuilder enum Captions { static func buildExpression(_ r: LocalizedStringResource) -> String { r.key };
            static func buildBlock(_ p: String...) -> String { p.joined() } }
        protocol Captioned { @Captions func f(for due: Date) -> String }
        struct Card: Captioned { func f(for due: Date) -> String { let none: Date? = nil; "Hello" } }
        """,
        // An initializer the package adds to `String` is reached by `String`'s own name.
        """
        extension String { init(caption r: LocalizedStringResource) { self = r.key } }
        func f() -> String { let d: Date? = nil; _ = d; return String(caption: "Hi") }
        """,
        // A `Sendable` or `Any` the package hands back can be a function value to cast and call.
        """
        func reader() -> Sendable { let r: @Sendable () -> Date = Date.init; return r }
        func f() -> Date? { let d: Date? = nil; _ = d; guard let r = reader() as? @Sendable () -> Date else {
            return nil }; return r() }
        """,
        // A trailing closure binds to a labelled parameter: `first { }` can be `first(where:)`.
        """
        struct T { func first(where ok: (Int) -> Bool) -> () -> UInt64 { mach_absolute_time } }
        func f() -> UInt64 { let d: [Date] = []; let r = T().first { $0 > 0 }; return r() + UInt64(d.count) }
        """,
        // A method of a local type still sees its function's locals.
        """
        func outer() -> Double { typealias max = Date; struct S { func f() -> Double { let d: Date = max();
            return d.timeIntervalSince1970 } }; return S().f() }
        """,
    ])
    func answeredElsewhere(source: String) throws {
        let finder = NamedFunctions(named: "f")
        finder.walk(Parser.parse(source: source))
        let function = try #require(finder.found.last)
        #expect(inferrer(for: source).verdict(for: function) == .refuted, "\(source)")
    }

    @Test("the signature, a shorthand binding and `super` are read as code", arguments: [
        "func f<T: ExpressibleByStringLiteral>() -> T { let d: Date? = nil; _ = d; return \"x\" }",
        "func f(_ m: Date.Type) -> Double { let d: Date? = nil; _ = d; return m.distantPast.timeIntervalSince1970 }",
        "func f() -> Int { let d: [Date] = []; if let optarg { return Int(optarg.pointee) + d.count }; return 0 }",
        "class C: NSObject { func f() -> Int { let d: [Date] = []; return super.hash + d.count } }",
    ])
    func signatureAndShorthand(source: String) throws {
        let tree = Parser.parse(source: source)
        let functions = tree.statements.compactMap { $0.item.as(FunctionDeclSyntax.self) }
            + tree.statements.compactMap { $0.item.as(ClassDeclSyntax.self) }
                .flatMap { $0.memberBlock.members.compactMap { $0.decl.as(FunctionDeclSyntax.self) } }
        let function = try #require(functions.first)
        #expect(inferrer(for: source).verdict(for: function) == .refuted, "\(source)")
    }

    @Test(
        "a call matching the package's labels, a static on a standard type, and an extension member resolve",
        arguments: [
            """
            func shift(_ d: Date, by days: Int = 0) -> Date { d }
            func f(_ m: M) -> Date { let d: Date = m.date; return shift(d, by: 0) }
            """,
            "func f(_ m: M) -> Int { let d: Date = m.date; return Int.max - Int(d.timeIntervalSince1970) }",
            // A value type's `Identifiable` conformance brings no identity: it declares its own `id`.
            """
            struct Row: Identifiable, Hashable { let id: Int; let at: Date }
            func f(_ m: M) -> Row { let d: Date = m.date; return Row(id: 1, at: d) }
            """,
        ]
    )
    func resolvesPackageCall(source: String) throws {
        #expect(try lastFunctionVerdict(source) == .pure, "\(source)")
    }

    /// A local counts only where it is in scope; otherwise the name is whatever it shadowed.
    @Test("a local declared out of scope does not stand in for a global", arguments: [
        """
        func f(_ m: M) -> Int { let d: Date = m.date; do { let time = 0; _ = time };
            return time(nil) + Int(d.timeIntervalSince1970) }
        """,
        """
        func f(_ m: M) -> Int { let d: Date = m.date; let time = time(nil); return time + Int(d.timeIntervalSince1970) }
        """,
        """
        func f(_ m: M, _ x: Int?) -> Int { let d: Date = m.date; if let mktemp = x { return mktemp } else {
            return Int(mktemp(nil)) + Int(d.timeIntervalSince1970) } }
        """,
        """
        func f(_ m: M, _ x: Int?) -> Int { let d: Date = m.date; if gethostid() > 0, let gethostid = x {
            return gethostid }; return Int(d.timeIntervalSince1970) }
        """,
        """
        func f(_ m: M, _ xs: [Int]) -> Int { let d: Date = m.date; for rand in xs where rand > 0 { _ = rand };
            return Int(rand()) + Int(d.timeIntervalSince1970) }
        """,
    ])
    func outOfScopeLocal(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    @Test("a local in scope resolves", arguments: [
        """
        func f(_ m: M, _ x: Int?) -> Int { let d: Date = m.date; guard let shift = x else { return 0 };
            return shift + Int(d.timeIntervalSince1970) }
        """,
        """
        func f(_ m: M, _ xs: [Int]) -> Int { let d: Date = m.date; var total = 0;
            for step in xs where step > 0 { total += step }; return total + Int(d.timeIntervalSince1970) }
        """,
        """
        func f(_ m: M, _ x: Int?) -> Int { let d: Date = m.date; if let shift = x, shift > 0 { return shift };
            return Int(d.timeIntervalSince1970) }
        """,
        """
        func f(_ m: M, _ r: Result<Int, Error>) -> Int { let d: Date = m.date; switch r {
            case .success(let n): return n + Int(d.timeIntervalSince1970); case .failure: return 0 } }
        """,
    ])
    func inScopeLocal(source: String) throws {
        #expect(try verdict(source) == .pure, "\(source)")
    }

    // MARK: - The blocklist: ambient reads, even where the package declares the name

    @Test("text, settings and clocks keep a type position refuting", arguments: [
        "func f(_ m: M) -> String { let d: Date = m.date; return \"\\(d)\" }",
        // `description` is the package's own on `M`, and still refuses: on a `Date` it formats.
        "func f(_ m: M) -> String { let d: Date = m.date; return d.description }",
        "func f(_ m: M) -> String { let d: Date = m.date; return String(describing: d) }",
        """
        func f(_ m: M) -> Int { let d: Date = m.date;
            return Calendar(identifier: .gregorian).component(.hour, from: d) }
        """,
        "func f(_ m: M) -> String { let d: Date = m.date; let df = DateFormatter(); return df.string(from: d) }",
        "func f(_ m: M) -> Int { let d: Date = m.date; return TimeZone(identifier: \"UTC\")!.secondsFromGMT(for: d) }",
        """
        func f(_ m: M) -> Date? { let d: Date? = m.date;
            return DateComponents(calendar: .current, year: 2020).date ?? d }
        """,
        "func f(_ m: M) -> Int { let d: Date = m.date; return Int(d.timeIntervalSince1970) + time(nil) }",
        "func f(_ m: M) -> Double { let d: Date = m.date; return d.timeIntervalSince1970 + CACurrentMediaTime() }",
        """
        func f(_ m: M) -> Double { let d: Date = m.date;
            return d.timeIntervalSince1970 + ProcessInfo.processInfo.systemUptime }
        """,
        """
        func f(_ m: M) -> Bool { let d: Date = m.date;
            return NSPredicate(format: "%@ < now()", d as NSDate).evaluate(with: nil) }
        """,
        """
        func f(_ m: M) -> UInt64 { let d: Date = m.date; var g = SystemRandomNumberGenerator();
            return g.next() + UInt64(d.timeIntervalSince1970) }
        """,
        """
        func f(_ m: M) -> Int { @AppStorage("k") var seen = 0; let d: Date = m.date;
            return seen + Int(d.timeIntervalSince1970) }
        """,
        // A clock behind a property: RxSwift's `drainQueue` reads `self.scheduler.now`.
        "func f(_ s: S) -> Double { let t: Date = s.scheduler.now; return t.timeIntervalSince1970 }",
        "func f(_ s: S) -> Double { let t: Date? = s.provider.currentDate; return t?.timeIntervalSince1970 ?? 0 }",
        "func f(_ m: M) -> String { let d: Date = m.date; return String(format: \"%.0f\", d.timeIntervalSince1970) }",
    ])
    func gated(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    @Test("the gate names what blocked it", arguments: [
        ("let d: Date = m.date; return \"\\(d)\"", "string interpolation"),
        ("let d: Date = .init()", ".init"),
        ("let c = Calendar(identifier: .gregorian)", "Calendar"),
        ("let n = time(nil)", "time()"),
        ("let x: Date = Self()", "Self()"),
        ("let t: Date = m.scheduler.now", ".now"),
        ("let d: Date = m.date; _ = mkstemp(nil)", "`mkstemp`"),
        ("let s = String(format: \"%d\", 1)", "format:"),
    ] as [(String, String)])
    func blockerIsNamed(body: String, blocker: String) throws {
        let source = "func f(_ m: M) { \(body) }"
        let bodySyntax = Syntax(try #require(try function(source).body))
        #expect(inferrer(for: source).dateInertnessBlocker(in: bodySyntax) == blocker)
    }

    // MARK: - Where the type still means the value

    /// A parameter's type is what its default's implicit member builds, so it never relaxes.
    @Test("a defaulted parameter's type still refutes", arguments: [
        "func f(at d: Date = .init()) -> Double { d.timeIntervalSince1970 }",
        "func f(id: UUID = .init()) -> String { id.uuidString }",
    ])
    func defaultedParameter(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    @Test("a Date or UUID written as an expression still refutes", arguments: [
        "func f() -> Date { Date() }",
        "func f() -> String { UUID().uuidString }",
        "func f(_ m: M) -> Date { let d: Date = m.date; return Date.distantPast > d ? d : Date() }",
        "func f() -> Any.Type { Date.self }",
    ])
    func expressionPosition(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    // MARK: - Other entry points

    @Test("a computed property and a closure relax the same way")
    func otherEntryPoints() throws {
        let source = """
        struct S {
            var stamps: Int { let d: [Date: Int] = [:]; return d.count }
            var stamped: String { let d: Date? = nil; return "\\(String(describing: d))" }
        }
        let tally = { (xs: [Int]) -> Int in let d = [UUID](); return d.count + xs.count }
        """
        let tree = Parser.parse(source: source)
        // A member's body relaxes only where the package's names show its type is wholly the package's.
        let inferrer = inferrer(for: source)
        let accessors = tree.statements.compactMap { $0.item.as(StructDeclSyntax.self) }
            .flatMap(\.memberBlock.members)
            .compactMap { $0.decl.as(VariableDeclSyntax.self)?.bindings.first?.accessorBlock }
        try #require(accessors.count == 2)
        #expect(inferrer.isPure(accessors[0]))
        #expect(!PurityInferrer().isPure(accessors[0]))
        #expect(!inferrer.isPure(accessors[1]))
        let closures = tree.statements
            .compactMap { $0.item.as(VariableDeclSyntax.self)?.bindings.first?.initializer?.value }
            .compactMap { $0.as(ClosureExprSyntax.self) }
        let closure = try #require(closures.first)
        #expect(inferrer.isPure(closure))
    }
}
