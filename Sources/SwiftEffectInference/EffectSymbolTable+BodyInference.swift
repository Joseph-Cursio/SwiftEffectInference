import SwiftSyntax

// MARK: - Body-based inference orchestration

extension EffectSymbolTable {

    /// Body inference whose heuristic resolver does not need the enclosing file.
    ///
    /// The import-aware form exists because some heuristics are gated on what a file imports
    /// (Fluent's `save`/`delete` only mean what they look like when `FluentKit` is in scope).
    /// A resolver that consults no imports has no use for the second parameter, and saying so
    /// is clearer than threading an ignored argument through every call site.
    public mutating func applyBodyInference(
        to sources: [SourceFileSyntax],
        multiHop: Bool = false,
        maxHops: Int = 5,
        wallClockBudget: Duration = .seconds(30),
        heuristicEffectForCall: @escaping (FunctionCallExprSyntax) -> Effect?
    ) {
        applyBodyInference(
            to: sources,
            multiHop: multiHop,
            maxHops: maxHops,
            wallClockBudget: wallClockBudget
        ) { call, _ in
            heuristicEffectForCall(call)
        }
    }

    /// Runs body-based upward inference across every source in `sources`,
    /// using the supplied resolver to classify un-annotated callees via
    /// `CallSiteEffectInferrer`-equivalent logic. Populates the upward
    /// inference cache.
    ///
    /// `multiHop: false` (default) is single-pass: each function's effect
    /// is computed from its callees' declared and heuristic-downward
    /// effects. `multiHop: true` iterates to fixed-point so callers of
    /// upward-inferred functions can themselves be inferred.
    public mutating func applyBodyInference(
        to sources: [SourceFileSyntax],
        multiHop: Bool = false,
        maxHops: Int = 5,
        wallClockBudget: Duration = .seconds(30),
        heuristicEffectForCall: (FunctionCallExprSyntax, SourceFileSyntax) -> Effect?
    ) {
        let deadline = ContinuousClock.now.advanced(by: wallClockBudget)

        runInferencePass(
            sources: sources,
            includeUpward: false,
            maxHops: maxHops,
            deadline: deadline,
            heuristicEffectForCall: heuristicEffectForCall
        )

        guard multiHop else { return }

        for _ in 0..<maxHops {
            if ContinuousClock.now >= deadline { return }
            let previous = upwardInferredEffects.mapValues { $0.effect }
            runInferencePass(
                sources: sources,
                includeUpward: true,
                maxHops: maxHops,
                deadline: deadline,
                heuristicEffectForCall: heuristicEffectForCall
            )
            let current = upwardInferredEffects.mapValues { $0.effect }
            if previous == current { return }
        }
    }

    private mutating func runInferencePass(
        sources: [SourceFileSyntax],
        includeUpward: Bool,
        maxHops: Int,
        deadline: ContinuousClock.Instant,
        heuristicEffectForCall: (FunctionCallExprSyntax, SourceFileSyntax) -> Effect?
    ) {
        for source in sources {
            if ContinuousClock.now >= deadline { return }
            let inferred = BodyEffectInferrer.inferEffects(in: source) { call in
                if let sig = FunctionSignature.from(call: call) {
                    if isCollision(signature: sig) { return nil }
                    if let declared = effect(for: sig) {
                        // The one anchor a human wrote. Everything that
                        // reaches a conclusion through here, and only
                        // through here, is annotation-backed.
                        return BodyInference(effect: declared, depth: 0, anchor: .declared)
                    }
                    if includeUpward, let upward = upwardInference(for: sig) {
                        // Inherits whatever the prior pass established —
                        // an anchor is a property of the whole chain, so a
                        // multi-hop result is only as clean as the step it
                        // stood on.
                        return upward
                    }
                }
                if let heuristic = heuristicEffectForCall(call, source) {
                    // A name or framework match. Correct often enough to be
                    // worth having and wrong often enough that a consumer
                    // must be able to decline it.
                    return BodyInference(effect: heuristic, depth: 0, anchor: .heuristic)
                }
                return nil
            }
            for (sig, result) in inferred {
                guard entriesBySignature[sig]?.effect == nil else { continue }
                let cappedDepth = min(maxHops, result.depth)
                let cappedResult = BodyInference(
                    effect: result.effect, depth: cappedDepth, anchor: result.anchor
                )
                upwardInferredEffects[sig] = mergedInference(
                    existing: upwardInferredEffects[sig],
                    incoming: cappedResult
                )
            }
        }
    }

    /// Combines the prior pass's inference with this pass's inference for a
    /// single signature. Effect rises monotonically (lub of the two);
    /// depth takes the max so a long chain established earlier isn't
    /// shrunk by a subsequent shorter equivalent.
    private func mergedInference(
        existing: BodyInference?,
        incoming: BodyInference
    ) -> BodyInference {
        guard let existing else { return incoming }
        let mergedEffect = existing.effect.lub(incoming.effect)
        let mergedDepth = max(existing.depth, incoming.depth)
        // The anchor follows the *effect*, not the depth, because it is a claim
        // about what justifies the value being reported. When one side's effect
        // wins the lub outright, only that side's justification is in play; the
        // loser's anchor describes a value nobody is reporting. On a tie the
        // stronger anchor wins, matching `combine`: either justification alone
        // supports the same value, so an annotation-backed one is available.
        let mergedAnchor: BodyInference.Anchor
        if incoming.effect.rank > existing.effect.rank {
            mergedAnchor = incoming.anchor
        } else if existing.effect.rank > incoming.effect.rank {
            mergedAnchor = existing.anchor
        } else {
            mergedAnchor = BodyInference.Anchor.strongest(existing.anchor, incoming.anchor)
        }
        return BodyInference(effect: mergedEffect, depth: mergedDepth, anchor: mergedAnchor)
    }
}
