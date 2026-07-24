import SwiftParser
import SwiftSyntax
import Testing
@testable import SwiftEffectInference

/// Exercises the canonical `PurityInferrer` — the shared oracle that decides
/// whether a function is `Effect.pure` (referential transparency).
@Suite
struct PurityInferrerTests {

    private let inferrer = PurityInferrer()

    /// Parses `source` and returns the inferred effect of the first `func`.
    private func effectOfFirstFunction(in source: String) -> Effect? {
        let tree = Parser.parse(source: source)
        let function = tree.statements.lazy
            .compactMap { $0.item.as(FunctionDeclSyntax.self) }
            .first
        guard let function else { return nil }
        return inferrer.inferredEffect(for: function)
    }

    @Test
    func transparentFunction_inferredPure() {
        let effect = effectOfFirstFunction(in: """
        func add(_ lhs: Int, _ rhs: Int) -> Int { lhs + rhs }
        """)
        #expect(effect == .pure)
    }

    @Test
    func loggingFunction_refutesPure() {
        // `print` is observational to the retry-safety lattice but NOT pure —
        // the case the `pure` tier exists to capture.
        let effect = effectOfFirstFunction(in: """
        func add(_ lhs: Int, _ rhs: Int) -> Int {
            print("adding")
            return lhs + rhs
        }
        """)
        #expect(effect == nil)
    }

    @Test
    func randomness_refutesPure() {
        let effect = effectOfFirstFunction(in: """
        func pick(_ values: [Int]) -> Int { values.randomElement() ?? 0 }
        """)
        #expect(effect == nil)
    }

    @Test
    func clockReading_refutesPure() {
        // `Date()` reads the system clock — nondeterministic, not a function of
        // the inputs.
        let effect = effectOfFirstFunction(in: """
        func stamp(_ id: Int) -> Double { Date().timeIntervalSince1970 + Double(id) }
        """)
        #expect(effect == nil)
    }

    @Test
    func uuidGeneration_refutesPure() {
        let effect = effectOfFirstFunction(in: """
        func tag(_ name: String) -> String { UUID().uuidString + name }
        """)
        #expect(effect == nil)
    }

    @Test
    func cfAbsoluteTime_refutesPure() {
        let effect = effectOfFirstFunction(in: """
        func elapsed(_ since: Double) -> Double { CFAbsoluteTimeGetCurrent() - since }
        """)
        #expect(effect == nil)
    }

    @Test
    func deterministicDateConstruction_isConservativelyRefuted() {
        // KNOWN, ACCEPTED over-refutation: `Date(timeIntervalSince1970: x)` is a
        // *deterministic* function of its input and is genuinely pure, but the
        // token scan can't distinguish it from the no-arg `Date()`. Refuting it
        // is the sound direction (withhold `.pure` rather than risk claiming it
        // for a clock read). This test pins that behavior so it stays intentional
        // — the AST-precise carve-out lives in SwiftProjectLint's rule.
        let effect = effectOfFirstFunction(in: """
        func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
        """)
        #expect(effect == nil)
    }

    @Test
    func forceUnwrap_refutesPure() {
        let effect = effectOfFirstFunction(in: """
        func first(_ values: [Int]) -> Int { values.first! }
        """)
        #expect(effect == nil)
    }

    @Test
    func fatalError_refutesPure() {
        let effect = effectOfFirstFunction(in: """
        func parse(_ text: String) -> Int {
            guard let value = Int(text) else { fatalError("bad input") }
            return value
        }
        """)
        #expect(effect == nil)
    }

    @Test
    func asyncFunction_refutesPure() {
        let effect = effectOfFirstFunction(in: """
        func fetch(_ id: Int) async -> Int { id }
        """)
        #expect(effect == nil)
    }

    @Test
    func throwingFunction_refutesPure() {
        let effect = effectOfFirstFunction(in: """
        func parse(_ text: String) throws -> Int { Int(text) ?? 0 }
        """)
        #expect(effect == nil)
    }

    @Test
    func bodylessDeclaration_refutesPure() {
        let effect = effectOfFirstFunction(in: """
        protocol P { func f(_ x: Int) -> Int }
        """)
        #expect(effect == nil)
    }

    @Test
    func isPure_matchesInferredEffect() throws {
        let tree = Parser.parse(source: "func square(_ x: Int) -> Int { x * x }")
        let function = try #require(tree.statements.first?.item.as(FunctionDeclSyntax.self))
        #expect(inferrer.isPure(function))
        #expect(inferrer.inferredEffect(for: function) == .pure)
    }

    // MARK: - verdict(for:) — partiality separated from transparency

    /// Parses `source` and returns the verdict on the first `func`.
    private func verdictOfFirstFunction(in source: String) -> PurityVerdict {
        let tree = Parser.parse(source: source)
        let function = tree.statements.lazy
            .compactMap { $0.item.as(FunctionDeclSyntax.self) }
            .first
        guard let function else { return .refuted }
        return inferrer.verdict(for: function)
    }

    /// The case the whole distinction exists for: `throws` narrows the domain, it
    /// does not refute transparency. A function that rejects inputs it cannot map
    /// is a deterministic function of its inputs everywhere else, and a consumer
    /// that can narrow a law to the success set is entitled to say so.
    @Test
    func throwingTransparentFunction_isPureButPartial() {
        #expect(verdictOfFirstFunction(in: """
        func parse(_ text: String) throws -> Int { Int(text) ?? 0 }
        """) == .pureButPartial)

        #expect(verdictOfFirstFunction(in: """
        func parse(_ text: String) throws -> Int {
            guard let value = Int(text) else { throw ParseError.bad }
            return value
        }
        """) == .pureButPartial)
    }

    /// **The gate that keeps the partial tier sound.** `throws` was doing double
    /// duty as an impurity refuter: nearly all Swift I/O throws, so gating on it
    /// masked every marker the set does not name. Relaxing it without this check
    /// judged a subprocess-spawning function pure — the lattice-bottom mistake.
    ///
    /// A throw raised by the function itself is partiality. A throw propagated
    /// from a callee is doubt about the callee, and doubt refutes.
    @Test
    func propagatedThrow_refutedNotPartial() {
        // Subprocess — the `runSwiftLint` shape that exposed this.
        #expect(verdictOfFirstFunction(in: """
        func runTool(_ executable: URL) throws -> Data {
            let process = Process()
            process.executableURL = executable
            try process.run()
            return Data()
        }
        """) == .refuted)

        // File read through an initializer the marker set does not name.
        #expect(verdictOfFirstFunction(in: """
        func read(_ url: URL) throws -> String {
            try String(contentsOf: url, encoding: .utf8)
        }
        """) == .refuted)

        // `try?` is propagation too — it still calls something that throws.
        #expect(verdictOfFirstFunction(in: """
        func read(_ url: URL) throws -> String? {
            try? String(contentsOf: url, encoding: .utf8)
        }
        """) == .refuted)
    }

    /// A `throws` function that never actually throws is partial-at-worst: the
    /// signature widens the domain the caller must handle, the body does not.
    @Test
    func declaredThrowsWithNoThrow_isPureButPartial() {
        #expect(verdictOfFirstFunction(in: """
        func decorate(_ text: String, with suffix: String) throws -> String { text + suffix }
        """) == .pureButPartial)
    }

    @Test
    func transparentTotalFunction_isPure() {
        #expect(verdictOfFirstFunction(in: """
        func add(_ lhs: Int, _ rhs: Int) -> Int { lhs + rhs }
        """) == .pure)
    }

    /// `async` is NOT the parallel of `throws`: there is no sub-domain on which an
    /// awaiting body is referentially transparent, so it refutes outright rather
    /// than earning the partial tier — including when it also throws.
    @Test
    func asyncFunction_refutedNotPartial() {
        #expect(verdictOfFirstFunction(in: """
        func fetch(_ id: Int) async -> Int { id }
        """) == .refuted)

        #expect(verdictOfFirstFunction(in: """
        func fetch(_ id: Int) async throws -> Int { id }
        """) == .refuted)
    }

    /// Partiality is the *only* clause `.pureButPartial` relaxes. A throwing
    /// function that also reads the clock or performs I/O stays refuted — the
    /// tier is not a back door around the impurity refuters.
    @Test
    func throwingImpureFunction_stillRefuted() {
        #expect(verdictOfFirstFunction(in: """
        func stamp(_ label: String) throws -> String { "\\(label) \\(Date())" }
        """) == .refuted)

        #expect(verdictOfFirstFunction(in: """
        func emit(_ label: String) throws -> Int { print(label); return label.count }
        """) == .refuted)
    }

    /// A `throws` function whose body can trap is refuted, not partial: `try` is
    /// recoverable and `fatalError` is not, so the caller cannot narrow its way
    /// out of the second one.
    @Test
    func throwingTrappingFunction_stillRefuted() {
        #expect(verdictOfFirstFunction(in: """
        func parse(_ text: String) throws -> Int {
            guard let value = Int(text) else { fatalError("bad input") }
            return value
        }
        """) == .refuted)
    }

    @Test
    func bodylessDeclaration_refuted() {
        #expect(verdictOfFirstFunction(in: """
        protocol P { func f(_ x: Int) -> Int }
        """) == .refuted)
    }

    /// The compatibility contract the additive change rests on: every existing
    /// consumer asking `isPure` / `inferredEffect` gets exactly its old answer,
    /// because both are defined as `verdict == .pure`. In particular
    /// `.pureButPartial` must read as NOT pure to a caller that never opted in.
    @Test
    func legacyAnswersAreUnchangedByTheNewTier() throws {
        let sources = [
            "func add(_ lhs: Int, _ rhs: Int) -> Int { lhs + rhs }",
            "func parse(_ text: String) throws -> Int { Int(text) ?? 0 }",
            "func fetch(_ id: Int) async -> Int { id }",
            "func stamp() -> String { \"\\(Date())\" }"
        ]
        for source in sources {
            let tree = Parser.parse(source: source)
            let function = try #require(tree.statements.first?.item.as(FunctionDeclSyntax.self))
            let verdict = inferrer.verdict(for: function)
            #expect(inferrer.isPure(function) == (verdict == .pure))
            #expect(inferrer.inferredEffect(for: function) == (verdict == .pure ? .pure : nil))
        }
    }
}
