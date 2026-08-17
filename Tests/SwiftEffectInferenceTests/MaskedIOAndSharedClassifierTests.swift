import SwiftParser
import SwiftSyntax
import Testing
@testable import SwiftEffectInference

/// Two holes in the marker sets, closed together because the same census found
/// both and they fail the same way: the oracle claimed `.pure` for code that
/// obviously is not.
///
/// ## Hole one — the I/O the `throws` gate never covered
///
/// `throwsOnlyItsOwnErrors` exists because gating on `throws` had been masking
/// *"`Process`, `Pipe`, `FileHandle`, `String(contentsOf:)`,
/// `Data(contentsOf:)`, the SQLite surface."* That gate re-closed the hole for
/// **throwing** functions. The non-throwing half stayed open, and
/// `FileHandle.standardError.write(_:)` does not throw.
///
/// Measured on SwiftInferProperties' `Sources/` before the fix: **7 non-refuted
/// functions wrote to standard error and were judged `.pure`**, including both
/// of that package's own `writeDiagnostic(_:)`.
///
/// ## Hole two — this module's own classifier, unconsulted
///
/// `NondeterminismSources` exists to end *"two implementations of 'does this
/// reach for ambient time' in two repositories."* `PurityInferrer` was carrying
/// a third — a hand-rolled token set whose doc pointed at SwiftProjectLint for
/// the precise forms, which had by then moved into this module. Seven sources
/// the classifier already recognised reached `.pure`.
///
/// ## Both were watched failing
///
/// Against the pre-fix inferrer every assertion in `holeOne` and `holeTwo`
/// fails. The controls below fail against the *obvious wrong fixes* instead —
/// which is the half that is easy to skip and the half that decides whether the
/// change is sound.
@Suite("Masked I/O, and the classifier this module already had")
struct MaskedIOAndSharedClassifierTests {

    private let inferrer = PurityInferrer()

    private func verdict(_ source: String) throws -> PurityVerdict {
        let tree = Parser.parse(source: source)
        let function = try #require(
            tree.statements.lazy.compactMap { $0.item.as(FunctionDeclSyntax.self) }.first
        )
        return inferrer.verdict(for: function)
    }

    // MARK: - Hole one

    @Test("writing to standard error is not pure, even without throws", arguments: [
        #"func f(_ t: String) { FileHandle.standardError.write(Data((t + "\n").utf8)) }"#,
        "func f() -> Process { let p = Process(); p.arguments = []; return p }",
        "func f() -> Pipe { Pipe() }"
    ])
    func holeOne(source: String) throws {
        #expect(try verdict(source) == .refuted)
    }

    // MARK: - Hole two

    @Test("a nondeterminism source this module classifies is not pure", arguments: [
        "func f() -> UInt64 { DispatchTime.now().uptimeNanoseconds }",
        "func f() -> ContinuousClock { ContinuousClock() }",
        "func f() -> SuspendingClock.Instant { SuspendingClock.now }",
        "func f() -> UInt64 { mach_absolute_time() }",
        "func f() -> Int32 { gettimeofday(nil, nil) }",
        "func f() -> String? { Locale.current.languageCode }",
        "func f() -> Int { TimeZone.current.secondsFromGMT() }"
    ])
    func holeTwo(source: String) throws {
        #expect(try verdict(source) == .refuted)
    }

    /// The **property** form matters on its own. `SuspendingClock.now`,
    /// `Locale.current` and `TimeZone.current` are member accesses, not calls, so
    /// a checker that visits only `FunctionCallExprSyntax` misses them entirely
    /// and this suite would still be green on the call-shaped half.
    @Test("the member-access overload is reached, not only the call one")
    func memberAccessSourcesAreReached() throws {
        #expect(try verdict("func f() -> String? { Locale.current.languageCode }") == .refuted)
        #expect(try verdict("func f() -> Int { 1 }") == .pure)
    }

    // MARK: - The controls

    /// **The union is a union, not a replacement.** The token set deliberately
    /// over-refutes: it cannot tell `Date()` from the perfectly deterministic
    /// `Date(timeIntervalSince1970:)`, and its doc argues that withholding
    /// `.pure` is the sound direction. `NondeterminismSources` is AST-precise and
    /// reads that initialiser as *not* a nondeterminism source.
    ///
    /// So swapping the token set out for the classifier would have **relaxed** a
    /// gate — the one thing this package's standing rules forbid doing to a
    /// purity gate. This control fails against that swap and passes against the
    /// union, which is the only test here that can tell them apart.
    @Test("the deliberate over-refutation survives — the classifier did not replace the tokens")
    func theTokenSetsOverRefutationIsPreserved() throws {
        #expect(try verdict("func f() -> Date { Date(timeIntervalSince1970: 0) }") == .refuted)
    }

    /// The refuters did not become a blanket. Without this, "everything refutes"
    /// would pass every assertion above.
    @Test("ordinary pure code is untouched", arguments: [
        "func f(_ a: Int, _ b: Int) -> Int { a + b }",
        "func f(_ xs: [Int]) -> [Int] { xs.map { $0 * 2 } }",
        "func f(_ s: String) -> String { s.uppercased() }",
        "func f(_ xs: [Int]) -> Int { xs.reduce(0, +) }"
    ])
    func pureCodeStaysPure(source: String) throws {
        #expect(try verdict(source) == .pure)
    }

    /// **The boundary, asserted rather than left to be discovered.** The token
    /// scan sees the *acquisition* of a handle, not its use through a parameter:
    /// a function handed a `FileHandle` and writing to it names no marker in its
    /// body and stays `.pure`.
    ///
    /// This is deliberate rather than overlooked. Refuting on the member name
    /// `write` would catch `String.write(to:)` and every `write` a package
    /// declares itself, which is a far broader net than the evidence supports.
    /// What such a function actually is, is *conditionally* impure — impure
    /// exactly when its caller hands it a real handle — which is the same shape
    /// SwiftInferProperties' item 33 census measured for function-typed
    /// parameters, arriving here for an ordinary one.
    @Test("a handle arriving as a parameter is still invisible, and that is the known edge")
    func aParameterHandleIsNotReached() throws {
        #expect(try verdict("func f(_ h: FileHandle, _ d: Data) { h.write(d) }") == .pure)
    }
}
