@testable import SwiftEffectInference
import Testing

extension TypePositionHandOffTests {

    // MARK: - Names a scope, an alias, a selector or the parser gives another meaning

    @Test(
        "a name an SDK extension or an inner alias rebinds, a hidden regex, or freed memory still refutes",
        arguments: [
            // Inside a type nested in an SDK extension, `Subject` is the SDK's member alias.
            """
            struct Subject { static let processInfo = Subject(); let globallyUniqueString = "" }
            extension ProcessInfo.PowerStateDidChangeMessage { struct Box { func f(_ info: Subject) -> String {
                let d: Date? = nil; _ = d; return info.globallyUniqueString } } }
            """,
            // An inner alias decides what a member's type is, whatever it is spelled like.
            """
            struct Shelf { typealias Error = String.Comparator;
                static var order: Error { String.Comparator(options: []) } }
            func f(_ xs: [String]) -> [String] { let d: Date? = nil; _ = d; return xs.sorted(using: Shelf.order) }
            """,
            // swift-syntax can read `/…/` as a regex where the compiler reads divisions, hiding its names.
            "func f(_ s: String) -> Bool { let d: Date? = nil; _ = d; return s.contains(/a+/) }",
            // `unowned(unsafe)` reads whatever freed memory holds.
            """
            final class Box { var count = 0 }
            final class Link { unowned(unsafe) let target: Box; init(target: Box) { self.target = target } }
            func f(_ l: Link) -> Int { let d: Date? = nil; _ = d; return l.target.count }
            """,
            """
            func f(_ n: Int) -> [Int: Int] { let d: Date? = nil; _ = d;
                return [Int: Int](_unsafeUninitializedCapacity: n, allowingDuplicates: true) { _, _ in n } }
            """,
        ]
    )
    func rebindingScope(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    @Test("a member type reached through an alias, a superclass or a postfix #if still refutes", arguments: [
        // An extension through an alias records its members where no lookup from the type finds them.
        """
        struct Shelf { var tag: String }
        typealias Stack = Shelf
        extension Stack { init(prefix: String, region: String = Locale.preferredLanguages.first ?? "") {
            self.init(tag: prefix + region) } }
        func f(_ p: String) -> String { let d: Date? = nil; _ = d; return Shelf(prefix: p).tag }
        """,
        // A subclass finds its superclass's member alias before any top-level type of that name.
        """
        struct Order {}
        class Base { typealias Order = String.StandardComparator }
        final class Shelf: Base { func order() -> Order { .localizedStandard } }
        func f(_ xs: [String], shelf: Shelf) -> [String] { let d: Date? = nil; _ = d;
            return xs.sorted(using: shelf.order()) }
        """,
        // A postfix `#if` hides a member's base.
        """
        enum Shelf { struct Comparator { init(rank: Int) {} } }
        func f(_ xs: [String]) -> [String] { let d: Date? = nil; _ = d; return xs.sorted(using: String
        #if true
        .Comparator(options: [])
        #endif
        ) }
        """,
    ])
    func aliasedMemberType(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    @Test("a module selector or an underscored unsafe API still refutes", arguments: [
        """
        struct URL { static let homeDirectory = 0 }
        func f() -> Foundation::URL { let d: Date? = nil; _ = d; return .homeDirectory }
        """,
        """
        struct UUID {}
        typealias Token = Foundation::UUID
        func f() -> String { let d: Date? = nil; _ = d; return Token().uuidString }
        """,
        """
        func _withUnprotectedUnsafePointer(to x: Int, body: (Int) -> Int) -> Int { body(x) }
        func f(_ n: Int) -> Int { let d: Date? = nil; _ = d; return _withUnprotectedUnsafePointer(to: n) { $0 } }
        """,
    ])
    func selectorOrUnsafe(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    @Test(
        "a declaration availability hides, a file the parsers may read apart, or a class identity still refutes",
        arguments: [
            // `@available` can hide a package declaration from lookup, so the call binds to Darwin's.
            """
            enum Meter { @available(swift, obsoleted: 1.0) static func mach_approximate_time() -> UInt64 { 0 };
                static func f() -> UInt64 { let d: Date? = nil; _ = d; return mach_approximate_time() } }
            """,
            """
            @available(macOS 99, *) func toupper(_ c: Int32) -> Int32 { c }
            func f(_ c: Int32) -> Int32 { let d: Date? = nil; _ = d; return toupper(c) }
            """,
            // A regex literal anywhere in the file: swift-syntax and the compiler may lex it apart.
            "let pattern = /a+/\nfunc f(_ n: Int) -> Int { let d: [Date] = []; return n + d.count }",
            // A class's own `Identifiable` default is `ObjectIdentifier(self)`, even with a nested type around.
            """
            final class Cell: Identifiable { struct Tag {} }
            func f(_ a: Cell, _ b: Cell) -> Bool { let seen: [UUID] = []; return a.id < b.id && seen.isEmpty }
            """,
        ]
    )
    func availabilityAndMisreading(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    @Test("a type an untyped literal builds, or C's formatted output, still refutes", arguments: [
        """
        struct StringLiteralType: ExpressibleByStringLiteral { let tag = Locale.current.identifier;
            init(stringLiteral value: String) {} }
        func f() -> String { let d: Date? = nil; _ = d; let r = "region"; return r.tag }
        """,
        "enum Outer { struct IntegerLiteralType {} }\nfunc f() -> Int { let d: [Date] = []; return d.count }",
        """
        func snprintf(ptr: [CChar], _ n: Int, _ f: String, _ a: Double, _ b: Int) -> Int32 { 0 }
        func f(_ p: [CChar]) -> Int32 { let d: Date? = nil; _ = d; return snprintf(ptr: p, 8, "%.1f", 1.5, 0) }
        """,
    ])
    func literalTypeOrFormattedOutput(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    @Test("a package declaration spelled like a keyword still refutes", arguments: [
        """
        let `self` = arc4random_uniform
        func f(sides: UInt32) -> UInt32 { let seen: [UUID: Int] = [:]; return self(sides) + UInt32(seen.count) }
        """,
        "struct S { let n: Int; func f() -> Int { let d: [Date] = []; return self.n + d.count } }\nlet `Type` = 0",
    ])
    func keywordDeclaration(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    @Test("`self` inside a type still relaxes")
    func selfInsideType() throws {
        let source = "struct S { let n: Int; func f() -> Int { let d: [Date] = []; return self.n + d.count } }"
        #expect(try verdict(source) == .pure)
    }

    @Test("a base-less member or a macro's declarations still refute", arguments: [
        // `.preferredLocales` in a `Locale?` context is Foundation's static, whatever the package declares.
        """
        enum Region { case preferredLocales }
        func f(_ s: String) -> String { let d: Date? = nil; _ = d; return s.lowercased(with: .preferredLocales.first) }
        """,
        // A freestanding macro adds declarations no walk of the source sees.
        """
        import SwiftUI
        struct Stamp { #_EntryDefaultValue(Date().timeIntervalSince1970) }
        func f() -> Int { let d: [Date] = []; return d.count }
        """,
    ])
    func baselessOrMacro(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    @Test("a vocabulary constant written base-less still relaxes")
    func baselessConstant() throws {
        let source = "func f(_ xs: [Int]) -> Int { let d: [Date] = []; return xs.max() ?? .zero + d.count }"
        #expect(try verdict(source) == .pure)
    }

    @Test("key-value coding, a tilde path or an allocator's capacity still refutes", arguments: [
        """
        struct Ledger { func _bridgeToObjectiveC() -> Int { 0 };
            func dictionaryWithValues(forKeys k: [String]) -> [String: Any] { [:] } }
        func f(_ due: Date) -> Int { let d: Date? = nil; _ = d;
            return due._bridgeToObjectiveC().dictionaryWithValues(forKeys: ["timeIntervalSinceNow"]).count }
        """,
        """
        func f(_ n: Int) -> Int { let d: [Date] = []; var xs = [Int](); xs.reserveCapacity(n);
            return xs.capacity - n + d.count }
        """,
    ])
    func keyValueOrCapacity(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    @Test("a buffer address, a random split or a format still refutes", arguments: [
        """
        struct Splitter { func randomSplit(by f: Double) -> Int { 0 } }
        func f(_ xs: [Int]) -> Int { let d: Date? = nil; _ = d; return xs.randomSplit(by: 0.5).0.count }
        """,
        """
        struct Ledger { func withCString(_ b: (Int) -> Int) -> Int { 0 } }
        func f(_ s: String) -> Int { let d: Date? = nil; _ = d; return s.withCString { Int(bitPattern: $0) } }
        """,
        """
        struct Ledger { func appendingFormat(_ f: String, _ a: Int) -> String { f } }
        func f(_ s: String) -> String { let d: Date? = nil; _ = d; return s.appendingFormat("%p", 0) }
        """,
    ])
    func addressOrShadow(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    @Test("a value handed over as a standard-protocol existential still refutes", arguments: [
        """
        struct Sink { func encode(to e: Int) {} }
        var currentZone: Encodable { TimeZone.autoupdatingCurrent }
        func f(_ e: Encoder) { let d: Date? = nil; _ = d; try? currentZone.encode(to: e) }
        """,
    ])
    func protocolExistential(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    @Test("an initializer added to an SDK type, reached through sugar or an alias, still refutes", arguments: [
        """
        extension Array where Element == Int { init(slots n: Int, stamp: Int = time(nil)) {
            self = Array(repeating: stamp, count: n) } }
        func f(_ n: Int) -> [Int] { let d: Date? = nil; _ = d; return [Int](slots: n) }
        """,
        """
        extension Double { init(jitter b: Double, noise: UInt32 = arc4random_uniform(100)) {
            self = b + Double(noise) } }
        func f(_ b: Double) -> Double { let d: Date? = nil; _ = d; return TimeInterval(jitter: b) }
        """,
        """
        func f(_ xs: [Int]) -> [Int] { let d: Date? = nil; _ = d; var ys = xs;
            ys.replaceSubrange(Range(uncheckedBounds: (2, 0)), with: [1]); return ys }
        """,
    ])
    func foreignInitializer(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    @Test("a body in a protocol extension, or a storage-identity check, still refutes", arguments: [
        """
        protocol Greeting: RawRepresentable where RawValue == LocalizedStringResource {}
        extension Greeting { func f(_ s: Date) -> Bool { let seen: [Date: Int] = [:];
            return self.rawValue == "Hi" && seen.isEmpty } }
        """,
        """
        struct Ledger { func isTriviallyIdentical(to o: Ledger) -> Bool { true } }
        func f(_ a: [Int], _ b: [Int]) -> Bool { let d: Date? = nil; _ = d; return a.isTriviallyIdentical(to: b) }
        """,
    ])
    func protocolExtensionOrIdentity(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    @Test("a value-type identity and a cast to a concrete type still relax", arguments: [
        """
        struct Row: Identifiable { let id: Int }
        func f(_ a: Row, _ b: Row) -> Bool { let seen: [UUID] = []; return a.id < b.id && seen.isEmpty }
        """,
        "func f(_ xs: [Any]) -> Int { let none: Date? = nil; _ = none; return xs.compactMap { $0 as? Int }.count }",
    ])
    func concreteRelaxes(source: String) throws {
        #expect(try verdict(source) == .pure, "\(source)")
    }

    // MARK: - Scope

    @Test("a body inside another body, or a name a pattern does not bind, still refutes", arguments: [
        // A later outer local is what a local function's `max()` calls.
        """
        func outer() -> UInt64 { func f() -> UInt64 { let d: [Date] = []; return max() + UInt64(d.count) };
            let max = mach_approximate_time; return f() }
        """,
        // A local type's path is a package type's, whose member is spelled like the SDK clock.
        """
        struct Meter { func mach_approximate_time() -> UInt64 { 0 } }
        func outer() -> UInt64 { struct Meter { func f() -> UInt64 { let d: [Date] = [];
            return mach_approximate_time() + UInt64(d.count) } }; return Meter().f() }
        """,
        // A closure in a case pattern does not see the pattern's bindings, even under a nested `where`.
        """
        func f(_ v: (UInt64, Int)) -> UInt64 { let d: [Date: Int] = [:]; switch v {
            case (let mach_approximate_time, { () -> Int in for _ in [1] where mach_approximate_time() % 2 == 0 {
            return 1 }; return 0 }()): return mach_approximate_time + UInt64(d.count); default: return 0 } }
        """,
        """
        func f(_ v: (UInt64, Int)) -> UInt64 { let d: [Date: Int] = [:]; switch v {
            case (let mach_approximate_time, { () -> Int in switch 0 {
            case _ where mach_approximate_time() % 2 == 0: return 0; default: return 1 }
            }()): return mach_approximate_time + UInt64(d.count); default: return 0 } }
        """,
        // A parenthesized callee, a call's result called, and an address taken as an identity.
        """
        func f(_ v: (UInt, Int)) -> UInt { let seen: [Date: Int] = [:]; switch v {
            case (let clock, { () -> Int in for _ in [1] where (clock)() % 2 == 0 { return 1 };
            return 0 }()): return clock + UInt(seen.count); default: return 0 } }
        """,
        "func f(_ g: () -> () -> UInt64) -> UInt64 { let d: [Date] = []; return g()() + UInt64(d.count) }",
        """
        func f(_ n: Int) -> Int { let d: Date? = nil; _ = d; var x = n; return withUnsafePointer(to: &x) {
            Int(bitPattern: $0) } }
        """,
    ])
    func scopeAndCallee(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    @Test("a case's own `where` and a local function in the judged body still relax", arguments: [
        """
        struct M { let date: Date }
        func f(_ m: M, _ x: Int) -> Int { let d: Date = m.date; switch x {
            case let n where n > 0: return n + Int(d.timeIntervalSince1970); default: return 0 } }
        """,
        """
        func f(_ xs: [Int]) -> Int { let d: [Date] = []; func twice(_ n: Int) -> Int { n * 2 };
            return xs.map(twice).count + d.count }
        """,
    ])
    func scopeRelaxes(source: String) throws {
        #expect(try verdict(source) == .pure, "\(source)")
    }
}
