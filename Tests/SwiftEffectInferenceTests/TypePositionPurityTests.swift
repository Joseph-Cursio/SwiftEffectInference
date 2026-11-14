@testable import SwiftEffectInference
import SwiftParser
import SwiftSyntax
import Testing

/// A `Date` or `UUID` that only names the type reads no clock and makes no identifier (#30), so it
/// no longer refutes a body that passes `DateInertnessChecker`. Every case that relaxes has a
/// partner here that must not: the same shape where the type conjures a value, a body that reaches
/// a name neither local, standard nor the package's own, and each family the blocklist refuses.
@Suite("A Date or UUID that only names the type")
struct TypePositionPurityTests {

    /// The package the bodies below are judged in: what `m.date`, `s.scheduler` and `dayKey` are.
    private static let package = """
    struct M { let date: Date; let stamp: Date?; var description: String { "" } }
    struct S { let scheduler: Scheduler; let provider: Provider }
    struct Scheduler { var now: Date { m.date } }
    struct Provider { var currentDate: Date? { nil } }
    struct Reading { let date: Date; let remaining: Int }
    struct Tally { let date: Date; let total: Int }
    func dayKey(_ d: Date) -> Int { Int(d.timeIntervalSince1970 / 86_400) }
    """

    func function(_ source: String) throws -> FunctionDeclSyntax {
        try #require(
            Parser.parse(source: source).statements.lazy.compactMap { $0.item.as(FunctionDeclSyntax.self) }.first
        )
    }

    func inferrer(for source: String) -> PurityInferrer {
        let trees = [Parser.parse(source: Self.package), Parser.parse(source: source)]
        return PurityInferrer(constructionFacts: .build(from: trees))
    }

    func verdict(_ source: String) throws -> PurityVerdict {
        inferrer(for: source).verdict(for: try function(source))
    }

    // MARK: - Part 1: a type position does not refute

    @Test("naming the type in a body is not reading the clock", arguments: [
        "func count(_ xs: [Int]) -> Int { let d: [Date: Int] = [:]; return d.count + xs.count }",
        "func f(_ m: M) -> Date { let d: Date = m.date; return d }",
        "func g(_ xs: [Int]) -> Int { let d: Date? = nil; return xs.count + (d == nil ? 0 : 1) }",
        "func f(_ m: M) -> Date { let d: Foundation.Date = m.date; return d }",
        "func f(_ ids: [Int]) -> Int { var seen: Set<UUID> = []; seen.removeAll(); return ids.count + seen.count }",
        "func f(_ xs: [Any]) -> Int { xs.filter { $0 is UUID }.count }",
        "func f(_ xs: [Any]) -> [Date] { xs.compactMap { $0 as? Date } }",
        "func f(_ ds: [Date]) -> [Double] { ds.map(\\Date.timeIntervalSince1970) }",
        "func f(_ ds: [Date]) -> [Date] { ds.sorted { (a: Date, b: Date) -> Bool in a < b } }",
    ])
    func typePosition(source: String) throws {
        #expect(try verdict(source) == .pure, "\(source)")
    }

    /// The witness #30 measured: the instant is injected, and only a nested helper's return type
    /// spelled the type (SwiftLintRuleStudioTeam's `auditLog`).
    @Test("a nested helper's signature does not refute the injected-clock function")
    func nestedHelperSignature() throws {
        let source = """
        func auditLog(events: [Int], asOf now: Date) -> [Date] {
            func daysAgo(_ days: Int) -> Date { now.addingTimeInterval(-Double(days) * 86_400) }
            return events.map(daysAgo)
        }
        """
        #expect(try verdict(source) == .pure)
    }

    /// `fleetBurndown`'s shape: a `[Date: Int]` local, and the package's own types and members.
    @Test("a body that reaches only the package's own names relaxes")
    func packageNames() throws {
        let source = """
        func burndown(_ readings: [Reading]) -> [Tally] {
            var byDate: [Date: Int] = [:]
            for reading in readings { byDate[reading.date, default: 0] += reading.remaining }
            return byDate.map { Tally(date: $0.key, total: $0.value + dayKey($0.key)) }.sorted { $0.date < $1.date }
        }
        """
        #expect(try verdict(source) == .pure)
    }

    @Test("without the package's names, only a body in locals and the standard library relaxes")
    func withoutPackageNames() throws {
        let local = try function(
            "func g(_ xs: [Int]) -> Int { let d: Date? = nil; return xs.count + (d == nil ? 0 : 1) }"
        )
        let member = try function("func f(_ m: M) -> Date { let d: Date = m.date; return d }")
        #expect(PurityInferrer().verdict(for: local) == .pure)
        #expect(PurityInferrer().verdict(for: member) == .refuted)
    }

    // MARK: - Part 3: an empty collection named as an expression

    @Test("an empty collection of dates builds no date", arguments: [
        "func h(_ xs: [Int]) -> Int { let d = [Date: Int](); return d.count + xs.count }",
        "func h(_ xs: [Int]) -> Int { let d = [UUID](); return d.count + xs.count }",
        "func h(_ xs: [Int]) -> Int { let d = [String: Date](); return d.count + xs.count }",
    ])
    func emptyCollection(source: String) throws {
        #expect(try verdict(source) == .pure, "\(source)")
    }

    @Test("a collection named as an expression and handed elements still refutes", arguments: [
        "func f() -> [Date] { [Date](repeating: .init(), count: 2) }",
        "func f(_ x: Date) -> [Date] { [Date](repeating: x, count: 2) }",
        "func f() -> [Date] { [Date](arrayLiteral: Date()) }",
    ])
    func filledCollection(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    // MARK: - Part 2: the type conjures a value

    @Test("an implicit member on a date- or UUID-typed binding still refutes", arguments: [
        "func f() -> Double { let d: Date = .now; return d.timeIntervalSince1970 }",
        "func f() -> Double { let d: Date = .init(); return d.timeIntervalSince1970 }",
        "func f() -> String { let u: UUID = .init(); return u.uuidString }",
        "func f() -> Int { let ds: [Date] = (0..<3).map { _ in .init() }; return ds.count }",
        "func f(_ m: [Int: Date]) -> Date { let table: [Int: Date] = m; return table[0, default: .init()] }",
        "func f(_ x: Date?) -> Date { let fallback: Date? = x; return fallback ?? .init() }",
        "func f(_ xs: [Int]) -> [Date] { func at(_ d: Date = .init()) -> Date { d }; return xs.map { _ in at() } }",
    ])
    func implicitMember(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    @Test("a type that can hand itself to code the body never spells still refutes", arguments: [
        // A generic's `T()` is a `Date` the body never names.
        """
        func f() -> Double { func make<T: Initable>() -> T { T() }; let d: Date = make();
            return d.timeIntervalSince1970 }
        """,
        "func f() -> Double { let d = make() as Date; return d.timeIntervalSince1970 }",
        "func f() -> Double { make<Date>().timeIntervalSince1970 }",
        // A local type or alias can carry the type into a protocol default.
        "func f() -> Int { struct Box { var at: Date }; return 0 }",
        "func f() -> Int { typealias Stamp = Date; return 0 }",
        // `Self()` in an extension of `Date`, and a metatype's `init()`.
        "func f(_ d: Date) -> Date { let x: Date = Self(); return x }",
        """
        func f(_ d: Date) -> Double { let x: Date? = nil;
            return Self.timeIntervalSinceReferenceDate + (x == nil ? 0 : 1) }
        """,
        "func f(_ d: Date) -> Date { let m: Date.Type = type(of: d); return m.init() }",
        "func f(_ meta: UUID.Type) -> String { let u: UUID = meta.init(); return u.uuidString }",
    ])
    func typeSuppliesValue(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    // MARK: - The allowlist: a name that is not local, standard or the package's

    /// Each of these got through a blocklist in review: the SDK is open, so only an allowlist closes.
    @Test("a body that reaches a name the package does not declare still refutes", arguments: [
        """
        func f(_ m: M) -> String { let d: Date? = m.stamp;
            return String.localizedStringWithFormat("%@", (d ?? m.date) as NSDate) }
        """,
        """
        func f(_ m: M) -> Int32 { let d: Date = m.date; var name = Array("/tmp/xXXXXXX".utf8CString);
            return mkstemp(&name) + Int32(d.timeIntervalSince1970) }
        """,
        """
        func f(_ m: M) -> Double { let d: Date = m.date;
            return Double(mach_approximate_time()) + d.timeIntervalSince1970 }
        """,
        "func f(_ m: M) -> Int { let d: Date = m.date; return Darwin.time(nil) + Int(d.timeIntervalSince1970) }",
        """
        func f(_ a: String, _ b: String) -> Bool { let d: Date? = nil;
            return a.localizedStandardCompare(b) == .orderedAscending && d == nil }
        """,
        "func f(_ m: M) -> Any? { let d: Date = m.date; return (d as NSDate).value(forKey: \"timeIntervalSinceNow\") }",
        "func f(_ m: M) -> UUID { let u: UUID? = nil; return u ?? (NSUUID.self.init() as UUID) }",
        """
        func f(_ m: M) -> Int { let d: Date = m.date; let read = time; return read(nil) + Int(d.timeIntervalSince1970) }
        """,
        """
        func f(_ m: M) -> String { let d: Date = m.date;
            return "istanbul".localizedCapitalized + String(Int(d.timeIntervalSince1970)) }
        """,
    ])
    func unresolvedName(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    /// A name that can stand for `Date` or `UUID` is not the package's own, though it declares it.
    @Test("an alias to a framework type, or a type parameter used as a value, still refutes", arguments: [
        """
        typealias Instant = Date
        func f(_ m: M) -> Double { let d: Date? = nil; return Instant().timeIntervalSince1970 + (d == nil ? 0 : 1) }
        """,
        """
        typealias Ident = UUID
        func f(_ m: M) -> String { let u: UUID? = nil; return Ident().uuidString + (u?.uuidString ?? "") }
        """,
        "func f<T: Initable>(_ seed: T) -> T { let d: Date? = nil; _ = d; return T() }",
        """
        protocol P { associatedtype V: Initable }
        struct Holder { let x: Int }
        func f(_ m: M) -> Int { let d: Date? = nil; _ = V(); return d == nil ? 0 : 1 }
        """,
    ])
    func standsForFrameworkType(source: String) throws {
        let functions = Parser.parse(source: source).statements.compactMap { $0.item.as(FunctionDeclSyntax.self) }
        let function = try #require(functions.first)
        #expect(inferrer(for: source).verdict(for: function) == .refuted, "\(source)")
    }

    @Test("an alias to the package's own type resolves")
    func aliasToPackageType() throws {
        let source = """
        typealias Row = Reading
        func f(_ rs: [Row]) -> Int { let d: [Date: Int] = [:]; return rs.count + d.count }
        """
        #expect(try lastFunctionVerdict(source) == .pure)
    }

    /// The verdict on the last function in `source`, the rest of which is the package around it.
    func lastFunctionVerdict(_ source: String) throws -> PurityVerdict {
        let functions = Parser.parse(source: source).statements.compactMap { $0.item.as(FunctionDeclSyntax.self) }
        return inferrer(for: source).verdict(for: try #require(functions.last))
    }
}
