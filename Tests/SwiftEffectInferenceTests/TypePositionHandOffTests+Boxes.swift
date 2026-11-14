@testable import SwiftEffectInference
import Testing

extension TypePositionHandOffTests {

    // MARK: - Boxes, existentials and identities

    @Test("a box the package hands over, or an identity it inherits, still refutes", arguments: [
        // A bare `Sequence` (no `any`) is a lazy map whose elements the caller computes.
        """
        func instants() -> Sequence { AnyIterator(Date.init) }
        func f(of due: Date) -> Double { let none: Date? = nil; _ = none; for case let now as Date in instants() {
            return now.timeIntervalSince(due) }; return 0 }
        """,
        """
        struct Feeds { var live: Swift.Sequence { AnyIterator(UUID.init) } }
        func f(_ s: Feeds) -> Int { let none: Date? = nil; _ = none; var n = 0; for _ in s.live { n += 1;
            if n > 2 { break } }; return n }
        """,
        // A cast recovers what an `Error` or a `Hashable` carried.
        """
        func f(_ e: Error) -> Int { let none: Date? = nil; _ = none; guard let s = e as? Sequence else { return 0 };
            var n = 0; for _ in s { n += 1 }; return n }
        """,
        "func f(_ v: Any) -> UUID? { let none: Date? = nil; _ = none; return (v as? () -> UUID)?() }",
        // A class's `Identifiable` default `id` is `ObjectIdentifier(self)`, inherited through a protocol.
        """
        let id = 0
        protocol Keyed: Identifiable {}
        final class Node: Keyed { func f(_ other: Node) -> Bool { let seen: [UUID] = [];
            return id < other.id && seen.isEmpty } }
        """,
        """
        struct Tag { let id: Int }
        protocol Keyed: Identifiable {}
        final class Node: Keyed {}
        func f(_ a: Node, _ b: Node) -> Bool { let seen: [UUID] = []; return a.id < b.id && seen.isEmpty }
        """,
        // `(String).Comparator` and `String.self` are types, whose statics no receiver check sees.
        """
        enum Order { case Comparator(options: Int) }
        func f(_ xs: [String]) -> [String] { let none: Date? = nil; _ = none;
            return xs.sorted(using: (String).Comparator(options: [])) }
        """,
    ])
    func boxesAndIdentities(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    @Test("a decoder, a hidden attribute, a pointer or a sugared type still refutes", arguments: [
        // A handed-over `Decoder` decodes dates with the strategy, and the time zone, that built it.
        """
        struct Box { let source: Decoder }
        func f(_ b: Box) throws -> [Date] { let none: Date? = nil; _ = none; return try Array(from: b.source) }
        """,
        // An attribute inside `#if` is still applied.
        """
        import SwiftUI
        struct Prefs {
        #if canImport(SwiftUI)
        @AppStorage("AppleLocale")
        #endif
        var localeID: String = ""
        }
        func f(_ p: Prefs) -> String { let none: Date? = nil; _ = none; return p.localeID }
        """,
        // A pointer handed to an initializer is read for as long as the count says.
        """
        func f(_ n: Int) -> [UInt16] { let anchor: Date? = nil; _ = anchor; var unit: UInt16 = 72;
            return Array(String(utf16CodeUnits: &unit, count: n).utf16) }
        """,
        // `[String].Element.Comparator` is `String.Comparator`, which collates in the user's locale.
        """
        struct Element { struct Comparator { init(options: Int) {} } }
        func f(_ xs: [String]) -> [String] { let none: Date? = nil; _ = none;
            return xs.sorted(using: [String].Element.Comparator(options: [])) }
        """,
    ])
    func decoderAttributePointer(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    @Test("a decoder the function is handed, and a package's own nested type, still relax", arguments: [
        """
        struct Row: Decodable { let n: Int }
        func f(_ d: Decoder) -> Int { let none: Date? = nil; _ = none; return (try? Row(from: d))?.n ?? 0 }
        """,
        """
        enum Outer { struct Inner { let n: Int } }
        func f(_ i: Outer.Inner) -> Int { let d: [Date] = []; return i.n + d.count }
        """,
    ])
    func handedDecoderRelaxes(source: String) throws {
        #expect(try verdict(source) == .pure, "\(source)")
    }

    @Test("a call the package's declaration cannot take, or a member a conformance infers, still refutes", arguments: [
        // An `async` or throwing package function is not what a plain call binds to.
        "func gethostid() async -> Int32 { 0 }\nfunc f() -> Int32 { let d: Date? = nil; _ = d; return gethostid() }",
        "func getpid() throws -> Int32 { 0 }\nfunc f() -> Int32 { let d: Date? = nil; _ = d; return getpid() }",
        // An `&` argument binds only to an `inout` parameter, and an `inout` parameter only to one.
        """
        func gethostname(_ b: [CChar], _ n: Int) -> Int32 { 0 }
        func f() -> Int { let d: Date? = nil; _ = d; var buffer = [CChar](repeating: 0, count: 64);
            _ = gethostname(&buffer, 64); return buffer.count }
        """,
        """
        func umask(_ m: inout UInt16) -> UInt16 { m }
        func f() -> UInt16 { let d: Date? = nil; _ = d; return umask(0) }
        """,
        // A raw identifier is not the dotted path it spells.
        """
        struct `Locale.Language` { static func systemLanguages() -> [Int] { [] } }
        extension Locale.Language { func f() -> Int { let d: Date? = nil; _ = d;
            return Locale.Language.systemLanguages.count } }
        """,
        // A wrapper's backing storage and a conformance's inferred member types are the type's own.
        """
        import SwiftUI
        let _launches = 0
        struct Prefs { @AppStorage("n") var launches = 0; func f() -> Int { let d: Date? = nil; _ = d;
            return _launches.wrappedValue } }
        """,
        """
        struct ID {}
        struct Ticket: Identifiable { let id: UUID; func f() -> String { let d: Date? = nil; _ = d;
            return ID().uuidString } }
        """,
        """
        struct Shelf { struct RawValue { struct Comparator { init(options: Int) {} } } }
        enum Tag: String { case a }
        func f(_ xs: [String]) -> [String] { let d: Date? = nil; _ = d;
            return xs.sorted(using: Tag.RawValue.Comparator(options: [])) }
        """,
        // A standard type decoded from a decoder is whatever the context infers, `Locale` among them.
        """
        func f(_ s: String, _ d: Decoder) -> String { let none: Date? = nil; _ = none;
            return s.lowercased(with: try? Optional(from: d) ?? nil) }
        """,
        // Memory never written.
        """
        func f(_ n: Int) -> [Int] { let d: Date? = nil; _ = d; return Array(unsafeUninitializedCapacity: n) {
            _, count in count = n } }
        """,
    ])
    func unbindableCall(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    @Test("an awaited-free plain call, an inout call and a package type's own member still relax", arguments: [
        """
        func bump(_ x: inout Int) { x += 1 }
        func f(_ n: Int) -> Int { let d: [Date] = []; var x = n; bump(&x); return x + d.count }
        """,
        """
        enum Tag: String { case a; static let fallback = 0 }
        func f() -> Int { let d: [Date] = []; return Tag.fallback + d.count }
        """,
    ])
    func plainCallRelaxes(source: String) throws {
        #expect(try verdict(source) == .pure, "\(source)")
    }

    // MARK: - Numbered members and platform buffers

    /// A raw identifier that starts with a digit is reached as a number (`Kinds.1()`, `self.0()`),
    /// a literal token no resolution sees, so a package that declares one is not judged at all.
    @Test("a member named with a number still refutes", arguments: [
        """
        enum Kinds { typealias `1` = Date }
        func f() -> Double { let d: [Date] = []; return Kinds.1().timeIntervalSince1970 + Double(d.count) }
        """,
        """
        enum Clock { static let `0x1`: () -> Date = Date.init }
        func f() -> Double { let d: [Date] = []; return Clock.0x1().timeIntervalSince1970 + Double(d.count) }
        """,
        """
        enum Clock { static let `0`: () -> Date = Date.init
            static func f() -> Double { let m: [Date: Int] = [:];
                return self.0().timeIntervalSince1970 + Double(m.count) } }
        """,
    ])
    func numberedMember(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    /// A tuple's element is spelled as a number too, and stays a tuple's element.
    @Test("a tuple element still relaxes")
    func tupleElementRelaxes() throws {
        let source = "func f(_ t: (Int, Int)) -> Int { let d: [Date] = []; return t.0 + t.1 + d.count }"
        #expect(try verdict(source) == .pure)
    }

    /// Bytes handed to a closure, offsets into them, and a platform string's pointer are addresses,
    /// whatever package member of the same name vouches for the call.
    @Test("a platform buffer's address still refutes", arguments: [
        """
        struct Ledger { func withBytes(_ b: (Int) -> Bool) -> Bool { b(0) } }
        func f(_ a: [UInt8], _ b: [UInt8]) -> Bool { let seen: [Date: Int] = [:];
            return a.withBytes { p in b.withBytes { q in p.count == q.count } } && seen.isEmpty }
        """,
        """
        struct Box { func withPlatformString(using seed: Int) -> Bool { seed == 0 } }
        func f(_ a: String, _ b: String) -> Bool { let seen: [Date: Int] = [:];
            return a.withPlatformString { p in b.withPlatformString { q in p == q } } && seen.isEmpty }
        """,
        """
        enum Probe { case byteOffsets(Int) }
        func f(_ a: [UInt8]) -> Int { let seen: [Date: Int] = [:]; return a.byteOffsets(0) + seen.count }
        """,
    ])
    func platformBuffer(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }
}
