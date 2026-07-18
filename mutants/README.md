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

The first two attack the join-semilattice the whole effect analysis rests on: a
`lub` that returns the safer effect would launder a dangerous one into a safe grade,
and a rank collision breaks the total order §26.3.3 deliberately keeps linear. The
third makes the purity inferrer admit `Date()` — the unearned-purity it exists to
refute (§26.3.1). All three verified killed.

## Adding a mutant

1. Make the buggy edit; 2. `git diff -- <file> > mutants/patches/<id>.patch`;
3. `git checkout -- <file>`; 4. add an entry to `manifest.json`.
