# SwiftEffectInference

Shared static-analysis library for classifying Swift functions and call sites by their **side-effect character** along a five-tier lattice:

```
pure < observational < idempotent < externally_idempotent < non_idempotent
```

`pure` (referential transparency — no side effects, deterministic, total) is the bottom: strictly stronger than `observational`, which permits reads/logging. The upper four tiers classify *retry-safety*; `pure` adds the *referential-transparency* axis a property-based test needs.

> **Status:** In use. The engines have been lifted from [SwiftProjectLint](https://github.com/Joseph-Cursio/SwiftProjectLint) per the migration plan in §10, and both consumers below compile against them. The full design lives in [`docs/SwiftEffectInference Design v0.2.md`](docs/SwiftEffectInference%20Design%20v0.2.md).

## The engines

- **`PurityInferrer`** — the canonical purity oracle for the toolchain. Answers `inferredEffect(for:)`, `verdict(for:)` (`pure` · `pureButPartial` · `refuted`, separating transparency from totality), and `isPure` over functions, closures and accessor blocks. Purity is a *conjunctive* property, so this **refutes** purity and never establishes it: any doubt refutes. It rejects on side-effect and nondeterminism markers, on `async`, on a body-less declaration, and on a non-total body. The markers are matched by bare identifier token, which over-refutes on purpose — `Date(timeIntervalSince1970:)` refutes alongside `Date()`, because a false refutation is the safe failure mode and a false `.pure` is not. A consumer wanting to *claim* `.pure` must take the meet with its own domain refuter.
- **`EffectAnnotationParser`** — read declared effects from `/// @lint.effect …` doc-comment grammar **and** [`swiftidempotency`](https://github.com/Joseph-Cursio/swiftidempotency)'s attribute grammar (`@Pure`, `@Idempotent`, `@NonIdempotent`, `@Observational`, `@ExternallyIdempotent(by:)`). Recognized attribute names are configurable. The doc-comment-only `/// @lint.effect transactional_idempotent` tier (parallel to `externallyIdempotent` in SwiftIdempotency's non-linear lattice) is *recognized* but conservatively projected onto `non_idempotent` to keep this lattice linear — see the decision note on `Effect`. The parser also recognizes an **orthogonal clock-determinism marker** (`/// @lint.determinism clock_deterministic` or `@ClockDeterministic`, surfaced via `isClockDeterministic(declaration:)`, not via `Effect`): a user claim that an `async` function is deterministic given an injected `Clock`. It deliberately does not touch the lattice — `.pure` implies synchronous — and exists so downstream consumers can relax async vetoes only where the claim is present; its runtime counterpart is SwiftPropertyLaws' `TimedAsyncSequence` law family.
- **`CallSiteEffectInferrer`** — classify call expressions by callee name + the file's imports. Framework-gated detection for FluentKit, Hummingbird, Vapor, AWSLambdaRuntime, and TCA; receiver-shape rules; CamelCase verb-prefix matching; stdlib-collection exclusion.
- **`BodyEffectInferrer`** — body-based call-graph inference; computes the lub of direct callees' effects with depth tracking. Closure boundaries (`Task { }`, `withTaskGroup`, `Task.detached`, SwiftUI `.task { }`) are not recursed into. Each `BodyInference` carries an `Anchor` (`.declared` / `.heuristic`) so a consumer can tell an author's annotation from a name-or-framework guess, and decline the guess if it wants to.

A unified **`EffectSymbolTable`** resolves declared and inferred effects with collision-withdrawal semantics.

## Consumers (today)

- **[SwiftProjectLint](https://github.com/Joseph-Cursio/SwiftProjectLint)** — uses the inferrers to feed lint rule enforcement (violations fire when annotated functions call functions at odds with declared effects).
- **[SwiftInferProperties](https://github.com/Joseph-Cursio/SwiftInferProperties)** — meets `PurityInferrer` with its own reducer-purity refuter to decide which functions a generated property test may safely run, and to surface "consider adding `/// @lint.effect pure`" advice for human review.

Both embed this library rather than shelling out to it — there is no CLI and no process boundary, which is the architectural point: the linter and the inference engine consult one purity oracle, so they cannot disagree about what is pure. That only holds while they pin the same revision, and this package carries no version tags, so both pin by revision.

The annotation grammars themselves are emitted by **[swiftidempotency](https://github.com/Joseph-Cursio/swiftidempotency)** (no inference dependency — it's a one-way producer).

## Build & test

```sh
swift package clean && swift test
```

The test target covers the lattice laws, both annotation grammars, purity refutation, call-site and body inference, and symbol-table resolution, plus a cost budget guarding the whole-domain purity path.

`swift package clean` matters: a partial rebuild can leave a stale test binary after a pull that touches package sources.

## License

MIT — see [LICENSE](LICENSE).
