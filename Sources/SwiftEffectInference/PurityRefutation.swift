import SwiftSyntax

/// **Why** purity was refuted — the witness `PurityVerdict` does not carry.
///
/// `PurityVerdict` says which clause failed (`.pure` / `.pureButPartial` /
/// `.refuted`); it does not say what failed it. That was fine while the only
/// consumers were gates — a rule that withholds a suggestion needs a Bool. It
/// stopped being fine as soon as a consumer wanted to *report* the refusal.
///
/// ## The two consumers that asked for this
///
/// **A rule that inventories what blocks a property test.** SwiftProjectLint's
/// closure and function candidate rules are purity-gated: a closure that fails
/// `isPure` is dropped without a word. So the numbers those rules publish are an
/// inventory of what is *already* testable, and the complement — the list of
/// things standing in the way, which is the half a reader acts on — is computed
/// on every run and discarded. A rule saying *this closure is impure* and not
/// what makes it so is not worth writing.
///
/// **A join that has to guess its own witness.** SwiftProjectLint's
/// `PackagePurityJoin` takes the meet of a package-local analysis with this
/// oracle's answer. Because it cannot ask *which* refuter fired, it infers a
/// witness from the `throws` clause — the one refutation reason that happens to
/// be visible in the signature — and stays narrower than it needs to be. Its own
/// header records that as a constraint on the build rather than a wish.
///
/// ## Shape
///
/// Every case names the thing, because naming the thing is the entire point. A
/// marker case carries the token as written; a nondeterminism case carries the
/// classifier's own `NondeterminismSource`, which already has a `marker` and a
/// `position`; a partiality case says which trap.
///
/// **First witness, not all of them.** The refuters short-circuit in a fixed
/// order (see `refutation(for:)`), and each walker keeps the first thing it saw.
/// A function can be impure for six reasons at once; reporting one true reason is
/// what a diagnostic needs, and collecting all six would cost every consumer the
/// early exits that `inferredEffect(for:)` exists to preserve.
public enum PurityRefutation: Sendable, Equatable {

    /// There is no body to inspect — a protocol requirement, or a `get`-only
    /// accessor declaration. Refuted for want of anything to read, not for
    /// anything found.
    case noBody

    /// The signature declares `async`. An `async` body awaits some effect, and
    /// unlike `throws` there is no sub-domain on which it is referentially
    /// transparent.
    case declaredAsync

    /// The signature declares `throws`, asked as a **whole-domain** question.
    ///
    /// Only `wholeDomainRefutation(for:)` and the closure form produce this.
    /// `refutation(for:)` does not: there, a `throws` function that raises only
    /// its own errors is `.pureButPartial`, which is not a refutation at all —
    /// see `PurityVerdict`.
    case declaredThrows

    /// A side-effect marker — I/O, logging, persistence — appeared as a bare
    /// token. Carries the token as written (`"FileManager"`, `"print"`).
    case sideEffectMarker(String)

    /// A nondeterminism marker appeared as a bare token. Carries the token as
    /// written (`"Date"`, `"shuffled"`).
    ///
    /// Distinct from `nondeterminismSource` because the token scan is
    /// deliberately shape-blind and over-refutes: it cannot tell `Date()` from
    /// `Date(timeIntervalSince1970:)`. A consumer that wants to say so — or to
    /// treat this as weaker evidence than the classifier's — needs the two
    /// separated, and a consumer that does not can ignore the distinction.
    case nondeterministicMarker(String)

    /// The module's AST-precise classifier recognised a nondeterminism source.
    /// Carries the classification, including its `marker` and `position`.
    case nondeterminismSource(NondeterminismSource)

    /// A file read spelled `SomeType(contentsOf:)`. Carries the callee as
    /// written with its label — `"String(contentsOf:)"`.
    case fileRead(String)

    /// Something in the body can trap, so the function has no return value for
    /// part of its domain.
    case partiality(Partiality)

    /// A parameter's **default value** refutes purity, and this is the reason it
    /// does. The default runs on exactly the calls that omit it, so it is part of
    /// the function even though nothing in the body says so.
    ///
    /// Indirect and recursive because the interesting half is the cause: *`now`
    /// defaults to something that reads the clock* is the diagnostic, and
    /// *`now` has a bad default* is not.
    indirect case refutingDefaultArgument(parameter: String, cause: PurityRefutation)

    /// A `throws` function propagates an error out of a callee — a `try`
    /// anywhere in the body. The throw, and whatever else the callee does, come
    /// from beyond what a leaf can see, so doubt refutes.
    ///
    /// See `throwsOnlyItsOwnErrors`: a function that raises only errors it
    /// constructs itself is `.pureButPartial` rather than refuted.
    case propagatedTry

    /// A closure assigns to a name it captured rather than declared. Carries the
    /// root name written through (`self` for `self.x = …`).
    ///
    /// The one capture-related refutation: a capture that is merely *read*
    /// becomes a parameter when the closure is lifted, and is not an impurity.
    case mutatesCapturedState(String)

    /// An accessor block carries something other than a getter. Carries the
    /// specifier as written (`"set"`, `"willSet"`, `"didSet"`, `"_modify"`).
    case notAGetter(String)

    /// Which trap breaks totality.
    public enum Partiality: Sendable, Equatable {

        /// `x!`
        case forceUnwrap

        /// `try!`
        case forcedTry

        /// `x as! T`
        case forcedCast

        /// `fatalError` / `precondition` / `assert` and family. Carries the
        /// callee as written.
        case trap(String)
    }
}

extension PurityRefutation: CustomStringConvertible {

    /// A one-line witness fit to put in a diagnostic.
    ///
    /// Consumers of this type are writing messages for a reader who has to decide
    /// what to do about the refusal, so the rendering names the thing rather than
    /// classifying it: *"reads the clock: `Date()`"*, not *"nondeterminism"*.
    public var description: String {
        switch self {
        case .noBody:
            return "has no body to inspect"

        case .declaredAsync:
            return "declares `async`"

        case .declaredThrows:
            return "declares `throws`, so it is not total over its domain"

        case .sideEffectMarker(let token):
            return "references the side-effect marker `\(token)`"

        case .nondeterministicMarker(let token):
            return "references the nondeterminism marker `\(token)`"

        case .nondeterminismSource(let source):
            return "reads \(Self.phrase(for: source.kind)): `\(source.marker)`"

        case .fileRead(let callee):
            return "reads a file: `\(callee)`"

        case .partiality(let partiality):
            return "can trap: \(partiality)"

        case .refutingDefaultArgument(let parameter, let cause):
            return "the default value of `\(parameter)` \(cause)"

        case .propagatedTry:
            return "propagates an error out of a callee (`try`)"

        case .mutatesCapturedState(let name):
            return "assigns to the captured `\(name)`"

        case .notAGetter(let specifier):
            return "declares `\(specifier)`, so it is not a derived value"
        }
    }

    private static func phrase(for kind: NondeterminismSource.Kind) -> String {
        switch kind {
        case .wallClockNow, .wallClockOffset: return "the wall clock"
        case .monotonicClock: return "a monotonic clock"
        case .clockAcquisition: return "an ambient clock"
        case .timedSuspension: return "an uninjected clock to sleep on"
        case .randomness: return "the system RNG"
        case .identity: return "a freshly generated identity"
        case .ambientEnvironment: return "the ambient environment"
        }
    }
}

extension PurityRefutation.Partiality: CustomStringConvertible {

    public var description: String {
        switch self {
        case .forceUnwrap: return "a force unwrap (`!`)"
        case .forcedTry: return "a `try!`"
        case .forcedCast: return "a forced cast (`as!`)"
        case .trap(let callee): return "`\(callee)`"
        }
    }
}
