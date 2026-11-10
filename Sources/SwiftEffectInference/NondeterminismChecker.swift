import SwiftSyntax

/// Finds any nondeterminism source this module's shared classifier recognises.
///
/// The classifier is consulted rather than re-derived: `NondeterminismSources`
/// is the type this package extracted so that "does this reach for ambient
/// time" has one implementation, and a purity oracle carrying a fourth copy of
/// the answer would be the drift that extraction exists to prevent.
///
/// Both overloads are needed. `source(of: FunctionCallExprSyntax)` catches
/// `ContinuousClock()`, `mach_absolute_time()`, `DispatchTime.now()`;
/// `source(of: MemberAccessExprSyntax)` catches the property forms —
/// `SuspendingClock.now`, `Locale.current`, `TimeZone.current` — which are not
/// calls at all and which a call-only walk misses entirely.
final class NondeterminismChecker: SourceAccurateSyntaxVisitor {

    /// The **first** source seen, which is the one a diagnostic names. The walk is
    /// not short-circuited — it never was — so keeping the first rather than the
    /// last costs nothing and makes the witness independent of tree order below
    /// the first hit.
    private(set) var source: NondeterminismSource?

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if source == nil { source = NondeterminismSources.source(of: node) }
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if source == nil { source = NondeterminismSources.source(of: node) }
        return .visitChildren
    }
}
