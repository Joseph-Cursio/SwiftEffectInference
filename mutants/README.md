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
| `marker-scan-reads-string-text` | purity-inference | killed | `stringLiteralText` |
| `marker-scan-reads-key-path-components` | purity-inference | killed | `keyPathComponent` |
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
| `alias-takes-the-first-collected` | construction-hole | killed | `nestedAliasNamesakes` |
| `alias-hides-the-written-name` | construction-hole | killed | `aliasDoesNotHijackAFrameworkName` |
| `alias-scope-ignored` | construction-control | killed | `constructionThroughNestedAlias` |
| `member-alias-not-followed` | construction-hole | killed | `memberAlias` |
| `lookup-loop-not-cut` | construction-memo | killed | `lookupThatComesBackToItselfEnds` |
| `lookup-asked-afresh` | construction-memo | killed | `spellingIsResolvedOncePerScope` |
| `lookup-key-forgets-the-scope` | construction-control | killed | `spellingIsResolvedOncePerScope` |
| `lookup-key-forgets-where-the-site-is` | construction-hole | killed | `inheritanceClauseAndBodyAreDifferentLookups` |
| `walk-outlives-its-pass` | construction-hole | killed | `longDelegationChain` |
| `decode-answer-outlives-its-pass` | construction-hole | killed | `decodeAnswerFollowsThePass` |
| `decode-proof-trusts-a-skip` | construction-hole | killed | `decodeThroughACycle` |
| `decode-asked-afresh` | construction-memo | killed | `decodeIsSearchedOncePerType` |
| `decode-proof-ignored` | construction-memo | killed | `decodeIsSearchedOncePerType` |
| `fit-asked-afresh` | construction-memo | killed | `shapeGuessUpNamesakeChains` |
| `fit-forgets-the-depth` | construction-control | killed | `shapeGuessUpNamesakeChains` |
| `reference-asked-afresh` | construction-memo | killed | `referenceUpNamesakeChains` |
| `built-table-keeps-its-memo` | construction-memo | killed | `builtTableHandsOnOnlyWhatNamesMean` |
| `every-call-located` | classifier-cost | killed | `chainClassifiesInLinearTime` |
| `own-index-by-namesakes` | construction-cost | killed | `subclassNamesakesScale` |
| `superclass-names-by-namesakes` | construction-cost | killed | `subclassNamesakesScale` |
| `self-members-per-namesake` | construction-cost | killed | `lookupsHoldEachDeclarationOnce` |
| `subtypes-by-scan` | construction-cost | killed | `selfInClassesScale` |
| `self-forgets-aliases-seen` | construction-cost | killed | `aliasMetAgainThroughSelfEnds` |
| `default-type-never-judged` | purity-unspelled | killed | `implicitMemberInDefaultArgument` |
| `default-type-always-judged` | purity-unspelled | killed | `typeWithoutImplicitMemberStaysPure` |
| `default-member-not-rebuilt` | purity-unspelled | killed | `currentDefault` |
| `implicit-member-in-closure-default-ignored` | purity-unspelled | killed | `implicitMemberInDefaultArgument` |
| `base-less-now-unmatched` | purity-unspelled | killed | `baseLessNow` |
| `now-matched-with-a-base` | purity-unspelled | killed | `nowThatIsNotBaseLess` |
| `time-interval-since-now-unmatched` | purity-unspelled | killed | `timeIntervalSinceNow` |
| `property-marker-not-read-in-key-path` | purity-unspelled | killed | `timeIntervalSinceNow` |
| `calendar-current-unmatched` | purity-unspelled | killed | `calendarCurrent` |
| `ambient-twins-unmatched` | purity-unspelled | killed | `calendarCurrent` |
| `current-matched-on-any-base` | purity-unspelled | killed | `calendarHandedIn` |
| `autoupdating-current-unmatched` | purity-unspelled | killed | `autoupdatingCurrent` |
| `formatted-unmatched` | purity-unspelled | killed | `formatted` |
| `syntax-formatting-not-exempt` | purity-unspelled | killed | `formattedThatIsNotAmbient` |
| `iso8601-not-exempt` | purity-unspelled | killed | `formattedThatIsNotAmbient` |
| `base-less-formatted-matched` | purity-unspelled | killed | `formattedThatIsNotAmbient` |
| `relative-to-now-unmatched` | purity-unspelled | killed | `relativeToNow` |
| `fresh-construction-unmatched` | purity-unspelled | killed | `relativeToNow` |
| `fresh-construction-takes-arguments` | purity-unspelled | killed | `notRelativeToNow` |
| `bridged-now-unmatched` | purity-unspelled | killed | `bridgedTwins` |
| `now-by-default-unmatched` | purity-unspelled | killed | `timeZoneReadsNow` |
| `now-by-default-given-an-instant` | purity-unspelled | killed | `timeZoneReadsAnInstant` |

The first two attack the join-semilattice the whole effect analysis rests on: a
`lub` that returns the safer effect would launder a dangerous one into a safe grade,
and a rank collision breaks the total order §26.3.3 deliberately keeps linear. The
third makes the purity inferrer admit `Date()` — the unearned-purity it exists to
refute (§26.3.1). All ten verified killed; the construction mutants below,
forty-eight more, the classifier's one, the five construction-cost ones, and
the twenty-two for the unspelled reads, likewise.

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

## `purity-unspelled`: a read that spells no marker

Twenty-two mutants for the clock and settings reads that spell no marker:

- an implicit member in a default, judged by its parameter's type and again with the
  type in front of it, closures included;
- a base-less `.now`, and `NSDate.now`;
- `timeIntervalSinceNow`, in a key path too;
- `Calendar.current` and its Objective-C twins, and `autoupdatingCurrent`;
- a `formatted(…)` call;
- `isDateInToday` and its siblings;
- a construction without arguments: `DateInterval()`, `NSDate()`, `NSUUID()`;
- a time zone's readers given no instant.

On `main` each was caught only when `Date` was written somewhere else in the same
body, so a function that took its date from a parameter was `.pure`.

Each check has a mutant that drops it. Most also have one that widens it past its
controls: an injected `clock.now`, `config.current`, swift-syntax's
`formatted(using:)`, an `.iso8601` style, a coding strategy's `.formatted(f)`, a
default that reads through no type, `DateInterval(start:end:)`, and
`secondsFromGMT(for:)`.

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

The three `alias-*` mutants come from one bug. Typealiases were followed
by bare name, and the first one collected won. Which types refuted then
depended on source order: B's `typealias Stamp = UUID` default went
unseen behind A's `Stamp = String`, and a `typealias UUID = String` in
one type hid a real `UUID` in every other. `alias-takes-the-first-collected`
puts that back. `alias-hides-the-written-name` lets an alias replace the
name it shares, where that name may be a framework type's. The control,
`alias-scope-ignored`, forgets that an alias its own type declares is
certain, and so charges A for B's alias.

`member-alias-not-followed` is the gap that fix left. Only an alias at the
head of a spelling was followed, so in `let s: Outer.Stamp = .init()`,
where `Outer` declares `typealias Stamp = UUID`, the default was judged
as the unknown `Outer.Stamp.init()`.

## `construction-memo`: what the memo may keep

`ConstructionMemo` keeps what names mean for a whole build, and what is refuted for one
pass, so that no question about constructing a type is answered twice. Its mutants
either keep too much — an answer read back in a scope or a pass it was not given for,
which changes verdicts, and is a `construction-hole` or `-control` like any other — or
are `construction-memo`: keep nothing, or keep it where no verdict reads it, which
changes no verdict, only what reaching one costs or who may share the table. Two of
those are killed by a clock: the shape guess and the initializer
reference up namesake chains, each over a minute without its memo, so each takes that
long to kill. A clock cannot see the rest — once names are kept, a search afresh is
cheap on any graph a test can build — so the memo counts resolutions and decode steps,
and the tests count with it. `lookup-loop-not-cut` is killed by the stack running out;
`built-table-keeps-its-memo` by the table a build returns still holding something a
judgement writes to.

## `classifier-cost`: what classifying a call costs

`NondeterminismSources.source(of:)` is asked of every call in every body `PurityInferrer`
checks, so what it costs per call is paid once per link of a member chain.
`every-call-located` locates each call before asking whether it is a source. A call's
position is its first token's, at the bottom of its chain, so a chain costs the square of
its length. No kind, marker or position changes, so a clock kills it: a chain four times as
long costs ~14× as much to classify, where linear is ~4×.

## `construction-cost`: what namesakes cost a build

In the swift compiler's tests, 23,000 files that are each their own program,
`class A` is declared 1,700 times, and every namesake is a candidate wherever
its name is written. An answer grows with the namesakes, so building the facts
is quadratic in them at best. Each of these mutants makes it cubic, or worse,
and changes no fact. `own-index-by-namesakes` passes every namesake to find a
class's own index, which `superclasses(of:)` needs for each candidate a
construction tries. `superclass-names-by-namesakes` does the same to find the
superclasses that every lookup inside a class reads. `subtypes-by-scan` passes
every declaration to find what `Self` in a class or protocol extension widens
to. A clock kills those three: four times the files cost ~64× as much, where
quadratic is ~16×, or ~16× where linear is ~4×. `self-members-per-namesake`
asks every namesake of `Self` for its members and keeps each answer, so a
lookup holds each declaration once per namesake. Counting kills that one.

`self-forgets-aliases-seen` costs without bound. `Self` starts the aliases seen
afresh, so `typealias F = Self.E` in a protocol that a type named `F` conforms
to reads `F.E` as `Self.E.E`, and so on, a new lookup every time, so the cut
for a lookup that comes back to itself never fires. The stack running out
kills it, as it kills `lookup-loop-not-cut`.

## Adding a mutant

1. Make the buggy edit; 2. `git diff -- <file> > mutants/patches/<id>.patch`;
3. `git checkout -- <file>`; 4. add an entry to `manifest.json`.
