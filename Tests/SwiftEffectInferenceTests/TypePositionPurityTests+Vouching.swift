@testable import SwiftEffectInference
import SwiftParser
import SwiftSyntax
import Testing

extension TypePositionPurityTests {

    // MARK: - What the context can build, and what the package cannot vouch for

    /// A literal or a base-less `.init(…)` takes its type from a context the body need not spell.
    @Test("a value typed by the signature or a callee's parameter still refutes", arguments: [
        "func f() -> Calendar { let d: Date? = nil; _ = d; return .init(identifier: .gregorian) }",
        "func f() -> LocalizedStringResource { let d: Date? = nil; _ = d; return \"Hi\" }",
        """
        func code(of resource: LocalizedStringResource) -> String { resource.key }
        func f() -> String { let d: Date? = nil; _ = d; return code(of: "probe") }
        """,
        "func f(_ xs: [Int]) -> [String] { let d: Date? = nil; _ = d; return xs.map(String.init) }",
        "func f(_ m: M) -> Date { let d: Date = m.date; return [d].map { _ in .init(timeIntervalSinceNow: 0) }[0] }",
    ])
    func contextTypedValue(source: String) throws {
        #expect(try lastFunctionVerdict(source) == .refuted, "\(source)")
    }

    /// A capture list is evaluated outside the closure, and a default outside the body.
    @Test("a capture or a default that reads outside the scope still refutes", arguments: [
        """
        func f() -> UInt64 { let d: [Date] = []; return { [mach_absolute_time] in mach_absolute_time()
            }() + UInt64(d.count) }
        """,
        "func f() -> Int32 { let d: [Date] = []; return { [pid = getpid] in pid() }() + Int32(d.count) }",
        "func f(t: UInt64 = mach_approximate_time()) -> UInt64 { let d: [Date] = []; return t &+ UInt64(d.count) }",
        "func f() -> Int { let d: [Date] = []; return `time`(nil) + d.count }",
    ])
    func outsideScope(source: String) throws {
        #expect(try lastFunctionVerdict(source) == .refuted, "\(source)")
    }

    /// The package can vouch only for a declaration a body could reach and that is judged somewhere.
    @Test("a name the package declares but cannot vouch for still refutes", arguments: [
        // A member of an unrelated type is not in scope as a free name.
        """
        struct Ticker { func mach_approximate_time() -> UInt64 { 0 } }
        func f() -> UInt64 { let d: [Date] = []; return mach_approximate_time() &+ UInt64(d.count) }
        """,
        // A type local to another function is not reachable.
        """
        func g() { enum Darwin { static func time(_: Int?) -> Int { 0 } } }
        func f() -> Int { let d: [Date] = []; return Darwin.time(nil) + d.count }
        """,
        // A global whose value is a library clock or random source.
        "let draw = arc4random\nfunc f() -> UInt32 { let d: [UUID] = []; return draw() &+ UInt32(d.count) }",
        // An alias spelled like a vocabulary member.
        """
        struct Box { typealias first = Date }
        func f() -> Double { let d: Date = Box.first(); return d.timeIntervalSince1970 }
        """,
        // A declaration only in an `#if` that may not be compiled.
        """
        #if os(Linux)
        func getuid() -> UInt32 { 0 }
        #endif
        func f() -> UInt32 { let d: [Date] = []; return getuid() &+ UInt32(d.count) }
        """,
        // A package generic whose `T` the annotation picks.
        """
        func make<T: Initable>() -> T { T() }
        func f() -> Double { let d: Date = make(); return d.timeIntervalSince1970 }
        """,
        // A type position resolves only to a type, not an enum case of the same spelling.
        """
        enum Keys { case NSError }
        func f(_ e: Error) -> Int { let d: [Date] = []; return (e as NSError).code + d.count }
        """,
    ])
    func unvouchedPackageName(source: String) throws {
        #expect(try lastFunctionVerdict(source) == .refuted, "\(source)")
    }

    @Test("a member of the enclosing type resolves without `self.`")
    func implicitSelfMember() throws {
        let source = """
        struct Ledger {
            let entries: [Reading]
            func total() -> Int { let seen: [Date: Int] = [:]; return entries.count + seen.count }
        }
        """
        let ledger = try #require(Parser.parse(source: source).statements.first?.item.as(StructDeclSyntax.self))
        let total = try #require(ledger.memberBlock.members.compactMap { $0.decl.as(FunctionDeclSyntax.self) }.first)
        #expect(inferrer(for: source).verdict(for: total) == .pure)
    }

    /// What reaches the body from the package must be something only the package's code can do.
    @Test("an SDK value or call the package hands the body still refutes", arguments: [
        // A returned locale, function value or key path is used in the body.
        """
        func viewer() -> Locale { .autoupdatingCurrent }
        func f(_ s: String) -> String { let d: Date? = nil; _ = d; return s.lowercased(with: viewer()) }
        """,
        """
        func stamper() -> () -> Date { Date.init }
        func f() -> Double { let d: Date = stamper()(); return d.timeIntervalSince1970 }
        """,
        """
        func age() -> KeyPath<Date, Double> { \\.timeIntervalSinceNow }
        func f(_ m: M) -> Double { let d: Date = m.date; return d[keyPath: age()] }
        """,
        // A package type that inherits SDK initializers and members.
        """
        final class Amount: NumberFormatter {}
        func f() -> Int { let d: [Date: Int] = [:]; return Amount().maximumFractionDigits + d.count }
        """,
        // A class's `Identifiable` default `id` is its fresh identity.
        "final class Node: Identifiable {}\nfunc f() -> Int { let u: UUID? = nil; _ = u; return Node().id.hashValue }",
        // A package overload with other labels does not make the SDK function the package's.
        """
        func getuid(_ x: Int) -> UInt32 { 0 }
        func f() -> UInt32 { let d: [Date] = []; return getuid() &+ UInt32(d.count) }
        """,
        // A function spelled like a type can lose its call to the SDK type.
        """
        func SortDescriptor(_ n: Int) -> Int { n }
        func f(_ xs: [String]) -> [String] { let d: [Date] = [];
            return xs.sorted(using: SortDescriptor(\\String.self)).dropFirst(d.count).map { $0 } }
        """,
        // An enum case's associated-value default is evaluated where the case is built.
        "enum Event { case at(Date = Date()) }\nfunc f() -> Event { let d: [Date] = []; _ = d; return Event.at() }",
        // A custom operator spells no name.
        """
        infix operator <~: AdditionPrecedence
        func <~ (lhs: Int, rhs: LocalizedStringResource) -> String { rhs.key }
        func f(_ d: Date) -> String { let held: Date = d; _ = held; return 0 <~ "Hi" }
        """,
        // `self` in a static member of an SDK type's extension is that type.
        """
        struct K { var timeIntervalSinceReferenceDate = 0.0 }
        extension Date { static func f() -> Double { let d: Date? = nil; _ = d;
            return self.timeIntervalSinceReferenceDate } }
        """,
    ])
    func handedByPackage(source: String) throws {
        let tree = Parser.parse(source: source)
        let functions = tree.statements.compactMap { $0.item.as(FunctionDeclSyntax.self) }
            + tree.statements.compactMap { $0.item.as(ExtensionDeclSyntax.self) }
                .flatMap { $0.memberBlock.members.compactMap { $0.decl.as(FunctionDeclSyntax.self) } }
        let function = try #require(functions.last { $0.name.text == "f" })
        #expect(inferrer(for: source).verdict(for: function) == .refuted, "\(source)")
    }
}
