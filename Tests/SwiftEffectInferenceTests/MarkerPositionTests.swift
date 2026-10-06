import SwiftParser
import SwiftSyntax
import Testing
@testable import SwiftEffectInference

/// The marker scan read every token's text, so a string literal and a key path's component were
/// matched as code. `"Date"` refuted a function that only returns a column title, and
/// `rows.map(\.random)` one that only reads each row's own `random`. Its doc already said what it
/// meant — "matched by bare-identifier token" — and now it does: an identifier, and not a key
/// path's component, which names a property where no marker is one.
///
/// Found by a sweep of the three repositories for code that took a key path's component for a
/// reference. The same quirk refuted every construction of a SwiftUI view with
/// `@AppStorage("shuffled")`, through `ConstructionFacts`.
@Suite("A marker is an identifier in code")
struct MarkerPositionTests {

    private func verdict(_ source: String) throws -> PurityVerdict {
        let tree = Parser.parse(source: source)
        let function = try #require(
            tree.statements.lazy.compactMap { $0.item.as(FunctionDeclSyntax.self) }.first
        )
        return PurityInferrer().verdict(for: function)
    }

    @Test("the text of a string literal is not a marker", arguments: [
        """
        func columnTitle(_ c: Int) -> String { switch c { case 0: return "Date"; default: return "Name" } }
        """,
        "func key() -> String { \"shuffled\" }",
        "func label() -> String { \"print\" }",
        "func banner() -> String { \"\"\"\n    UUID\n    \"\"\" }"
    ])
    func stringLiteralText(source: String) throws {
        #expect(try verdict(source) == .pure, "\(source)")
    }

    @Test("a key path's component is not a marker", arguments: [
        "func f(_ rows: [Row]) -> [Int] { rows.map(\\.random) }",
        "func f(_ rows: [Row]) -> [Bool] { rows.map(\\.print) }",
        "func f(_ rows: [Row]) -> [Int] { rows.map(\\.shuffled.count) }"
    ])
    func keyPathComponent(source: String) throws {
        #expect(try verdict(source) == .pure, "\(source)")
    }

    @Test("the code around them still is", arguments: [
        // An interpolation is code.
        "func stamp() -> String { \"at \\(Date())\" }",
        // A key path's root names a type.
        "func f(_ ds: [Date]) -> [Double] { ds.map(\\Date.timeIntervalSince1970) }",
        // A member name may be a static method — `Int.random` — so it is still matched.
        "func f(_ rows: [Row]) -> [Int] { rows.map { $0.random } }",
        // A subscript component's arguments are evaluated.
        "func f(_ rows: [[Int]]) -> [Int] { rows.map(\\.[Int.random(in: 0...1)]) }",
        "func f(_ rows: [Row]) -> [Int] { rows.map(\\.seed) + [Int.random(in: 0...9)] }"
    ])
    func surroundingCode(source: String) throws {
        #expect(try verdict(source) == .refuted, "\(source)")
    }

    @Test("a construction is not refuted by a string on the type it constructs")
    func appStorageKey() throws {
        let source = """
        struct Prefs { @AppStorage("shuffled") private var shuffled = false }
        func makePrefs() -> Prefs { Prefs() }
        """
        #expect(try constructionRefutation(of: "makePrefs", in: [source]) == nil)
    }
}
