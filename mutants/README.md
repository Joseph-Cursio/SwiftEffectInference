# Mutation / regression corpus (private)

A hand-authored mutant corpus for **sharpening the kit itself** — the effect lattice
and purity inferrer dogfooding on themselves (Chapter 30 §30.4.4). Mutants live in
SwiftEffectInference's own source and are killed by its own tests. Not a scored
benchmark — no frozen answer key.

Each mutant is a reversible patch (`patches/<id>.patch`). The runner applies one,
builds, runs its named killer test via `swift test --filter`, checks the outcome,
and reverts. SwiftPM targets test methods precisely, so a kill is attributed by
construction.

## Run

```sh
mutants/run-mutants.sh                    # all mutants
mutants/run-mutants.sh lub-returns-safer
```

Requires a clean working tree.

## The corpus (`manifest.json`)

| id | shape | expected | killer |
|---|---|---|---|
| `lub-returns-safer` | lattice-join | killed | `lub_dominatesBothInputs` |
| `rank-collision` | lattice-rank | killed | `rank_matchesExpectedOrdering` |
| `purity-admits-date` | purity-inference | killed | `nondeterminismIsImpure` |
| `witness-order-trap-before-marker` | purity-witness | killed | `markersOutrankTraps` |
| `default-witness-loses-its-parameter` | purity-witness | killed | `defaultArgumentCarriesBoth` |
| `throws-refutes-the-verdict-question` | purity-witness | killed | `onlyTheWholeDomainQuestionRefutesOnThrows` |
| `capture-witness-names-the-target-not-the-root` | purity-witness | killed | `capturedMemberWriteNamesTheBase` |
| `witness-keeps-the-last-trap` | purity-witness | killed | `firstTrapWins` |
| `construction-facts-ignored` | construction-hole | killed | `healthRecommendationShapeIsRefuted` |
| `construction-matched-as-bare-token` | construction-control | killed | `typeMentionStaysPure` |
| `static-default-runs-on-construction` | construction-control | killed | `staticAndLazyDefaultsDoNotRefute` |
| `construction-witness-drops-the-type` | construction-witness | killed | `healthRecommendationShapeIsRefuted` |
| `fixpoint-stops-after-one-pass` | construction-hole | killed | `nestedFactTypePropagates` |
| `omitted-default-ignores-written-labels` | construction-control | killed | `passingTheDefaultedLabelStaysPure` |
| `unlabelled-default-always-omitted` | construction-control | killed | `suppliedUnlabelledDefault` |
| `construction-follows-traps` | construction-control | killed | `trappingInitializerIsNotFollowed` |
| `qualified-callee-dropped` | construction-hole | killed | `everySpellingReachesTheFact` |
| `superclass-not-inherited` | construction-hole | killed | `subclassIsARefutedType` |
| `initializer-body-ignored` | construction-hole | killed | `explicitInitializerBody` |
| `certainty-ignores-shadowing` | construction-hole | killed | `localTypealiasShadows` |
| `local-types-become-members` | construction-hole | killed | `localTypeOutOfReach` |
| `local-types-reachable-everywhere` | construction-control | killed | `localTypeOutOfReach` |
| `shape-guess-skips-the-fit` | construction-control | killed | `shapeGuessNeedsAFit` |
| `unseen-initializer-is-clean` | construction-hole | killed | `unseenInitializer` |
| `witness-not-frozen` | construction-witness | killed | `witnessIsKept` |
| `implicit-member-not-qualified` | construction-hole | killed | `implicitMemberDefaults` |
| `implicit-member-outermost-type-only` | construction-hole | killed | `nestedImplicitMembers` |
| `closure-members-judged` | construction-control | killed | `implicitMemberInClosureDefault` |
| `self-not-widened` | construction-hole | killed | `dynamicSelf` |
| `protocol-initializers-dropped` | construction-hole | killed | `protocolExtensionInitializer` |
| `where-clause-refinement-ignored` | construction-hole | killed | `protocolExtensionInitializerConformers` |
| `raw-value-enum-not-raw-representable` | construction-hole | killed | `protocolExtensionInitializerConformers` |
| `protocol-extension-taken-by-namesake` | construction-hole | killed | `protocolExtensionInitializerConformers` |
| `contextual-init-ignored` | construction-hole | killed | `contextDecidesTheType` |
| `tuple-binds-by-position` | construction-hole | killed | `tupleShuffle` |
| `local-binding-missed` | construction-hole | killed | `assignmentToShadowingLocal` |
| `member-types-merged` | construction-control | killed | `memberTypesPerDeclaration` |
| `reference-charged-as-any-path` | construction-control | killed | `referenceOmitsNoDefault` |
| `implicit-super-init-ignored` | construction-hole | killed | `implicitSuperInitializer` |

The first two attack the join-semilattice the whole effect analysis rests on: a
`lub` that returns the safer effect would launder a dangerous one into a safe grade,
and a rank collision breaks the total order §26.3.3 deliberately keeps linear. The
third makes the purity inferrer admit `Date()` — the unearned-purity it exists to
refute (§26.3.1). All eight verified killed; the construction mutants below,
thirty-one more, likewise.

## `purity-witness`: a shape about what the oracle *says*

`purity-inference` asks *does the oracle still refute this?* The five mutants in
`purity-witness` leave that answer untouched and corrupt the **reason** — a defect
class the corpus could not reach until `PurityRefutation` made the reason public,
and one no assertion about pass or fail would notice. Two of them (`…-order-trap-…`,
`…-keeps-the-last-trap`) turn the reported witness into a fact about tree order or
about which entry point the caller used, with every verdict identical either way.

`throws-refutes-the-verdict-question` is the one that is not payload-only, and it is
here because re-expressing `verdict(for:)` as *the witness returned nothing* made it
possible: teaching the witness to refute on `throws` silently retires
`.pureButPartial` for every consumer.

## `purity-admits-date` stopped killing, and only a re-run said so

It survived from the day `hasRefutingMarker` gained its `NondeterminismSources`
pass — the classifier reaches `Date()` on its own, so removing the bare token left
the killer test passing. The token entry is still load-bearing, for the case its own
doc names: it is shape-blind and refutes `Date(timeIntervalSince1970:)`, which the
classifier reads as deterministic. That assertion is now in the killer.

**Re-run the whole corpus after any change to a refuter**, not just the mutants in
the shape you touched. A mutant that goes quiet does so silently.

## `construction-*`: what constructing a type runs

`ConstructionFacts` answers *what does `T(…)` run?* for every package type, so its
mutants come in three shapes. A `construction-hole` makes a construction that does
run a clock or an identity look clean — the facts ignored, a fixpoint cut short, a
local type made a member, an initializer body or a superclass not followed. A
`construction-control` makes a clean construction look dirty — a bare mention of a
type treated as constructing it, a default counted as omitted when the call writes
it, the shape guess charging a type no initializer of which fits. Over-refutation is
the cost the design accepts for its doubts, not one to pay for nothing, so each of
those is a defect too. A `construction-witness` leaves every verdict alone and
corrupts the reason.

Five of them survived their first run against the reachability rewrite — the
mutated line was no longer the only way to the answer: resolution already reached
the superclass, the shape guess already matched a labelled `.init`, the fixpoint
already stopped on a stable count. Each now has a test that sees what the mutant
still changes: the public `refutedTypeNames`, a witness kept across passes, the
unseen-initializer fallback, and a context that types an unlabelled `.init()`.

## Adding a mutant

1. Make the buggy edit; 2. `git diff -- <file> > mutants/patches/<id>.patch`;
3. `git checkout -- <file>`; 4. add an entry to `manifest.json`.
