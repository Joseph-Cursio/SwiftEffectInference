@testable import SwiftEffectInference
import SwiftParser
import SwiftSyntax
import Testing

/// Every function named `f`, nested or not, in source order.
private final class FunctionsNamedF: SyntaxVisitor {
    private(set) var found: [FunctionDeclSyntax] = []

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == "f" { found.append(node) }
        return .visitChildren
    }
}

/// What a package can hand a relaxed body without the body naming it (#30): a value it iterates or
/// calls, a default it leaves out, a conformance that makes an SDK value callable, or a scope that
/// gives a name another meaning. Each shape that must refute has a partner nearby that still relaxes.
@Suite("A Date or UUID named as a type, where the package hands something over")
struct TypePositionHandOffTests {

    /// The verdict on the last function named `f` in `source`, the whole of which is the package.
    func verdict(_ source: String) throws -> PurityVerdict {
        let tree = Parser.parse(source: source)
        let finder = FunctionsNamedF(viewMode: .sourceAccurate)
        finder.walk(tree)
        let function = try #require(finder.found.last)
        return PurityInferrer(constructionFacts: .build(from: [tree])).verdict(for: function)
    }

    // MARK: - A left-out declaration's name is refused, even where the vocabulary has it

    @Test("a member the package leaves out is not vouched for by the vocabulary", arguments: [
        // A property handing back an iterator over a clock: the body runs it while iterating.
        """
        struct Ticker { var first: AnyIterator<UInt64> { AnyIterator(mach_absolute_time) } }
        func f(_ t: Ticker) -> [UInt64] { let d: [Date] = []; _ = d; return Array(t.first.prefix(2)) }
        """,
        // An alias hides the function type's arrow.
        """
        typealias Reader = () -> UInt64
        struct T { var first: Reader { mach_absolute_time } }
        func f(_ t: T) -> UInt64 { let d: [Date] = []; let read = t.first; return read() + UInt64(d.count) }
        """,
        // A static the package adds to an SDK type, read as a vocabulary static.
        """
        extension String { static var max: AnyIterator<UInt64> { AnyIterator(mach_absolute_time) } }
        func f() -> [UInt64] { let d: [Date] = []; _ = d; return Array(String.max.prefix(2)) }
        """,
        // A key path to a left-out property.
        """
        struct Ticker { var first: AnyIterator<UInt64> { AnyIterator(mach_absolute_time) } }
        func f(_ ts: [Ticker]) -> [UInt64] { let d: [Date] = []; _ = d; return ts.map(\\.first).flatMap {
            Array($0.prefix(1)) } }
        """,
    ])
    func leftOutMember(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    // MARK: - A default argument runs in the caller

    @Test("a default the call leaves out is judged where it runs", arguments: [
        """
        struct Stamp { let lang: String; init(lang: String = Locale.preferredLanguages.first ?? "") {
            self.lang = lang } }
        func f() -> String { let d: Date? = nil; _ = d; return Stamp().lang }
        """,
        """
        func max(language: String = Locale.preferredLanguages.first ?? "") -> String { language }
        func f() -> String { let d: Date? = nil; _ = d; return max() }
        """,
        """
        struct Shelf { func sorted(by lang: String = Locale.preferredLanguages.first ?? "") -> [String] { [lang] } }
        func f(_ s: Shelf) -> [String] { let d: Date? = nil; _ = d; return s.sorted() }
        """,
        """
        enum Choice { case plain(String);
            static func some(_ s: String, language: String = Locale.preferredLanguages.first ?? "") -> Choice {
            .plain(s + language) } }
        func f(_ s: String) -> Choice { let d: Date? = nil; _ = d; return .some(s) }
        """,
        // A global whose initial value leaves out such a default, set on its first read.
        """
        func abs(language: String = Locale.preferredLanguages.first ?? "") -> String { language }
        let preferred = abs()
        func f() -> String { let d: Date? = nil; _ = d; return preferred }
        """,
    ])
    func omittedDefault(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    @Test("an inert default the call leaves out still relaxes")
    func inertDefault() throws {
        let source = """
        struct Stamp { let n: Int; init(n: Int = 0) { self.n = n } }
        func f() -> Int { let d: [Date] = []; return Stamp().n + d.count }
        """
        #expect(try verdict(source) == .pure)
    }

    // MARK: - Conformances, by the path they reach

    @Test("a conformance that brings members no body names still refutes", arguments: [
        // A typed throw hands the caller a value to call or iterate.
        """
        struct Stamp: Error { func callAsFunction() -> () -> UUID { UUID.init } }
        func trouble() throws(Stamp) { throw Stamp() }
        func f(for due: Date) -> String { let none: Date? = nil; _ = none; do { try trouble();
            return "" } catch { let make = error(); return make().uuidString } }
        """,
        """
        struct Burst: Error, Sequence { func makeIterator() -> AnyIterator<Date> { AnyIterator<Date>(Date.init) } }
        func ignite() throws(Burst) { throw Burst() }
        func f(of due: Date) -> Double { let none: Date? = nil; _ = none; do { try ignite();
            return 0 } catch { for now in error { return now.timeIntervalSince(due) }; return 0 } }
        """,
        // A qualified or shadowing protocol is not the standard one it is spelled like.
        """
        enum Outer { protocol Error {} }
        extension Outer.Error { func callAsFunction() -> () -> UUID { UUID.init } }
        struct Badge: Outer.Error {}
        func f(for due: Date) -> String { let none: Date? = nil; _ = none; let make = Badge()();
            return make().uuidString }
        """,
        """
        protocol Equatable {}
        extension Equatable { func callAsFunction() -> () -> Date { Date.init } }
        struct Meter: Equatable {}
        func f(of due: Date) -> Double { let none: Date? = nil; _ = none; let make = Meter()();
            return make().timeIntervalSince(due) }
        """,
        // A conformance added to an SDK type, or through an alias.
        """
        extension Date: @retroactive Sequence { public func makeIterator() -> AnyIterator<UUID> { AnyIterator {
            UUID() } } }
        func f(for due: Date) -> String { let none: Date? = nil; _ = none; for id in due { return id.uuidString };
            return "" }
        """,
        """
        struct Clockwork {}
        typealias Gear = Clockwork
        extension Gear: Sequence { func makeIterator() -> AnyIterator<Date> { AnyIterator(Date.init) } }
        func f(_ c: Clockwork) -> Double { let none: Date? = nil; _ = none; for t in c {
            return t.timeIntervalSince1970 }; return 0 }
        """,
    ])
    func handingConformance(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    @Test("a conformance resolved to a clean package type still relaxes", arguments: [
        """
        struct Coin { let v: Int }
        extension `Coin`: Equatable {}
        func f(_ c: Coin) -> Int { let d: [Date] = []; return c.v + d.count }
        """,
        """
        enum Outer { class Base { let n = 1 } }
        final class Probe: Outer.Base {}
        func f(_ p: Probe) -> Int { let d: [Date] = []; return p.n + d.count }
        """,
    ])
    func cleanConformance(source: String) throws {
        #expect(try verdict(source) == .pure, "\(source)")
    }
}
