import Foundation
import SwiftSyntax

// MARK: - Clock-determinism annotation (collections/async workplan Phase 4)

extension EffectAnnotationParser {

    /// Recognizes the *clock-determinism* marker: a user-declared claim that
    /// an `async` function's observable behavior is a deterministic function
    /// of its inputs **given an injected `Clock`** — time is a parameter,
    /// not an ambient effect. The claim's runtime counterpart is
    /// SwiftPropertyLaws' `TimedAsyncSequence` law family (PropertyLawAsync,
    /// v3.15.0+): `debounceIsDeterministicUnderTestClock` is exactly this
    /// property, checked.
    ///
    /// Deliberately **orthogonal to the `Effect` lattice**: `.pure`'s
    /// contract implies synchronous + total, and the retry-safety tiers say
    /// nothing about time. Mapping this claim onto an existing tier would
    /// silently weaken `.pure` (async functions could then claim it), and a
    /// new tier would ripple `Effect.rank` and every ordinal consumer. A
    /// standalone predicate lets downstream consumers (SwiftInferProperties'
    /// async hard-veto) take the *conjunction*: relax the veto only where
    /// this marker is present AND their own refuters stay quiet.
    ///
    /// Grammar mirrors the effect annotation's two forms:
    /// - doc comment: `/// @lint.determinism clock_deterministic` — its own
    ///   `@lint.determinism` namespace, since `@lint.effect` names lattice
    ///   tiers and this is not one;
    /// - attribute: `@ClockDeterministic`.
    ///
    /// Content-blind like every annotation here: presence is a claim for
    /// human review + law-checking, not an analysis result. No
    /// collision-withdraw applies — a Bool predicate has no disagreeing
    /// forms; either grammar alone marks the declaration.
    public func isClockDeterministic(declaration: FunctionDeclSyntax) -> Bool {
        hasClockDeterministicAttribute(declaration.attributes)
            || Self.hasClockDeterministicDocComment(Self.combinedDocTrivia(for: declaration))
    }

    /// Same combined-position scan for variable bindings (handler-style
    /// closures), mirroring `parseEffect(declaration:)`.
    public func isClockDeterministic(declaration: VariableDeclSyntax) -> Bool {
        hasClockDeterministicAttribute(declaration.attributes)
            || Self.hasClockDeterministicDocComment(Self.combinedDocTrivia(for: declaration))
    }

    /// Convenience for callers that don't customize attribute recognition.
    public static func isClockDeterministic(declaration: FunctionDeclSyntax) -> Bool {
        Self().isClockDeterministic(declaration: declaration)
    }

    /// Whether the author has declared the effect **cannot be determined**.
    ///
    /// SwiftIdempotency's `unknown` tier had been in the reference lattice from
    /// the start and was **inference-only** — no spelling, so an author who meant
    /// *"I cannot guarantee idempotency here"* had no way to write it down. The
    /// nearest sayable thing was `@NonIdempotent`, which claims something strictly
    /// stronger: *unconditionally* non-idempotent, re-invocation producing
    /// additional observable effects. `@EffectUnknown` closes that gap.
    ///
    /// **Deliberately not an `Effect` case, and not projected onto one.**
    /// `unknown` is *incomparable* to `non_idempotent`, so admitting it to this
    /// module's `Effect` would force a linear five-tier chain into a genuine
    /// partial order and replace the rank-only `lub(_:)` with a Hasse-diagram
    /// join. Note the contrast with `transactional_idempotent` a few lines up in
    /// `extractEffect`: that one *is* projected, conservatively, onto
    /// `.nonIdempotent`, because it is a claim that some tier holds. `unknown`
    /// is the absence of such a claim — projecting it would manufacture
    /// information the author explicitly declined to give.
    ///
    /// So it is read the way `@ClockDeterministic` is: its own predicate, outside
    /// `AttributeRecognition`, answering its own question.
    ///
    /// **What this changes for a caller.** Before this existed, `parseEffect`
    /// returned `nil` for `@lint.effect unknown` — the same answer it gives for an
    /// unannotated declaration and for a misspelled tier. A consumer could not
    /// distinguish *"the author said they do not know"* from *"the author said
    /// nothing"*, which is the whole content of the marker.
    ///
    /// Grammar mirrors the effect annotation's two forms:
    /// - doc comment: `/// @lint.effect unknown` — the `@lint.effect` namespace,
    ///   because `unknown` **is** a tier name in SwiftIdempotency's lattice even
    ///   though it is not one in this module's `Effect`;
    /// - attribute: `@EffectUnknown`.
    ///
    /// Content-blind like every annotation here: presence is a claim for human
    /// review, not an analysis result.
    public func declaresUnknownEffect(declaration: FunctionDeclSyntax) -> Bool {
        hasEffectUnknownAttribute(declaration.attributes)
            || Self.hasUnknownEffectDocComment(Self.combinedDocTrivia(for: declaration))
    }

    /// Same combined-position scan for variable bindings (handler-style
    /// closures), mirroring `parseEffect(declaration:)`.
    public func declaresUnknownEffect(declaration: VariableDeclSyntax) -> Bool {
        hasEffectUnknownAttribute(declaration.attributes)
            || Self.hasUnknownEffectDocComment(Self.combinedDocTrivia(for: declaration))
    }

    /// Convenience for callers that don't customize attribute recognition.
    public static func declaresUnknownEffect(declaration: FunctionDeclSyntax) -> Bool {
        Self().declaresUnknownEffect(declaration: declaration)
    }

    /// Names recognized as the unknown-effect marker attribute.
    static let effectUnknownAttributeNames: Set<String> = ["EffectUnknown"]

    func hasEffectUnknownAttribute(_ attributes: AttributeListSyntax) -> Bool {
        attributes.contains { element in
            guard let attr = element.as(AttributeSyntax.self),
                  let name = Self.attributeTypeName(attr.attributeName) else { return false }
            return Self.effectUnknownAttributeNames.contains(name)
        }
    }

    static func hasUnknownEffectDocComment(_ trivia: Trivia) -> Bool {
        docCommentLines(from: trivia).contains { line in
            guard let range = line.range(of: "@lint.effect") else { return false }
            return line[range.upperBound...].trimmingLeadingWhitespace().firstWord() == "unknown"
        }
    }

    /// Names recognized as the clock-determinism marker attribute.
    static let clockDeterministicAttributeNames: Set<String> = ["ClockDeterministic"]

    func hasClockDeterministicAttribute(_ attributes: AttributeListSyntax) -> Bool {
        attributes.contains { element in
            guard let attr = element.as(AttributeSyntax.self),
                  let name = Self.attributeTypeName(attr.attributeName) else { return false }
            return Self.clockDeterministicAttributeNames.contains(name)
        }
    }

    static func hasClockDeterministicDocComment(_ trivia: Trivia) -> Bool {
        docCommentLines(from: trivia).contains { line in
            guard let range = line.range(of: "@lint.determinism") else { return false }
            let token = line[range.upperBound...].trimmingLeadingWhitespace().firstWord()
            return token == "clock_deterministic"
        }
    }
}
