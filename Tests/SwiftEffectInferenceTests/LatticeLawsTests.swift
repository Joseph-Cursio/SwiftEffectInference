@testable import SwiftEffectInference
import Testing

/// Algebraic laws for the idempotency effect lattice — `Effect.lub` and
/// `Effect.rank` — owned at the source.
///
/// The lattice is a five-element chain:
///
///     pure < observational < idempotent < externallyIdempotent < nonIdempotent
///
/// Because the domain is finite and tiny, these laws are checked **exhaustively**
/// (every pair and every triple of the canonical elements) rather than by
/// random sampling — exhaustive enumeration is a stronger guarantee here and
/// keeps this package's single-dependency (`swift-syntax`) posture intact: only
/// the `Testing` framework the test target already uses is required.
///
/// Consumers (SwiftProjectLint, SwiftInferProperties) rely on these laws but no
/// longer host them; a change to `Effect.lub`/`Effect.rank` now fails here, in
/// the package that owns the type, rather than only in a downstream suite.
@Suite
struct LatticeLawsTests {

    /// The five canonical lattice elements, one per rank. `externallyIdempotent`
    /// uses `keyParameter: nil`; the associated value only affects same-rank
    /// tie-breaks, which are covered explicitly in the key-parameter tests.
    private static let canonical: [Effect] = [
        .pure,
        .observational,
        .idempotent,
        .externallyIdempotent(keyParameter: nil),
        .nonIdempotent
    ]

    /// Independent oracle for the intended ordering. Mirrors the lattice's rank
    /// rather than reading `Effect.rank`, so a change to the implementation's
    /// rank assignment disagrees with this oracle and the laws fail loudly.
    private static func expectedRank(_ effect: Effect) -> Int {
        switch effect {
        case .pure: 0
        case .observational: 1
        case .idempotent: 2
        case .externallyIdempotent: 3
        case .nonIdempotent: 4
        }
    }

    @Test
    func rank_matchesExpectedOrdering() {
        for effect in Self.canonical {
            #expect(effect.rank == Self.expectedRank(effect))
        }
    }

    // MARK: - Idempotence

    @Test
    func lub_ofEqualElements_isThatElement() {
        for effect in Self.canonical {
            #expect(effect.lub(effect) == effect)
            #expect(Effect.lub(of: [effect]) == effect)
            #expect(Effect.lub(of: [effect, effect]) == effect)
        }
    }

    // MARK: - Pairwise laws (all 16 pairs)

    @Test
    func lub_isCommutative() {
        for lhs in Self.canonical {
            for rhs in Self.canonical {
                // The canonical elements have distinct ranks, so full Equatable
                // commutativity holds; the same-rank tie-break (which is only
                // left-biased, not symmetric) is covered by the key-parameter
                // tests below.
                #expect(lhs.lub(rhs) == rhs.lub(lhs))
            }
        }
    }

    @Test
    func lub_dominatesBothInputs() {
        for lhs in Self.canonical {
            for rhs in Self.canonical {
                let bound = lhs.lub(rhs)
                #expect(bound.rank >= lhs.rank)
                #expect(bound.rank >= rhs.rank)
            }
        }
    }

    @Test
    func lub_isOneOfItsInputs() {
        for lhs in Self.canonical {
            for rhs in Self.canonical {
                let bound = lhs.lub(rhs)
                #expect(bound == lhs || bound == rhs)
            }
        }
    }

    // MARK: - Associativity (all 64 triples)

    @Test
    func lub_isAssociative() {
        for first in Self.canonical {
            for second in Self.canonical {
                for third in Self.canonical {
                    let leftFolded = first.lub(second).lub(third)
                    let rightFolded = first.lub(second.lub(third))
                    #expect(leftFolded == rightFolded)
                }
            }
        }
    }

    // MARK: - Collection form

    @Test
    func collectionLub_matchesPairwiseFold() {
        for lhs in Self.canonical {
            for rhs in Self.canonical {
                #expect(Effect.lub(of: [lhs, rhs]) == lhs.lub(rhs))
            }
        }
    }

    @Test
    func collectionLub_overAllCanonical_isTop() {
        #expect(Effect.lub(of: Self.canonical) == .nonIdempotent)
    }

    @Test
    func collectionLub_ofEmpty_isNil() {
        #expect(Effect.lub(of: []) == nil)
    }

    // MARK: - Same-rank tie-break (keyParameter, left-biased)

    @Test
    func keyParameterTieBreak_pairwise_keepsLeftOperand() {
        let left = Effect.externallyIdempotent(keyParameter: "first")
        let right = Effect.externallyIdempotent(keyParameter: "second")
        #expect(left.lub(right) == left)
        #expect(right.lub(left) == right)
        #expect(left.lub(right).rank == 3)
    }

    @Test
    func keyParameterTieBreak_collection_keepsFirstOccurrence() {
        let first = Effect.externallyIdempotent(keyParameter: "first")
        let second = Effect.externallyIdempotent(keyParameter: "second")
        #expect(Effect.lub(of: [first, second]) == first)
        #expect(Effect.lub(of: [second, first]) == second)
    }

    @Test
    func crossRank_preservesHigherRankKey() {
        let keyed = Effect.externallyIdempotent(keyParameter: "token")
        #expect(Effect.idempotent.lub(keyed) == keyed)
        #expect(keyed.lub(.idempotent) == keyed)
        #expect(Effect.nonIdempotent.lub(keyed) == .nonIdempotent)
    }

    // MARK: - `pure` is the lattice bottom

    @Test
    func pure_isStrictBottom() {
        #expect(Effect.pure.rank == 0)
        for effect in Self.canonical {
            // `pure` is dominated by every element (including itself): joining
            // anything with `pure` yields that other element.
            #expect(Effect.pure.lub(effect) == effect)
            #expect(effect.lub(.pure) == effect)
        }
    }

    @Test
    func pure_isStrictlyStrongerThanObservational() {
        // A pure function is observational, but not vice versa: the join of the
        // two is `observational`, and they are distinct elements.
        #expect(Effect.pure != Effect.observational)
        #expect(Effect.pure.rank < Effect.observational.rank)
        #expect(Effect.pure.lub(.observational) == .observational)
    }
}
