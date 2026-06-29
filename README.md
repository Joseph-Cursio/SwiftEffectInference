# SwiftEffectInference

Shared static-analysis library for classifying Swift functions and call sites by their **side-effect character** along a five-tier lattice:

```
pure < observational < idempotent < externally_idempotent < non_idempotent
```

`pure` (referential transparency — no side effects, deterministic, total) is the bottom: strictly stronger than `observational`, which permits reads/logging. The upper four tiers classify *retry-safety*; `pure` adds the *referential-transparency* axis a property-based test needs.

> **Status:** Pre-extraction skeleton. The full design lives in [`docs/SwiftEffectInference Design v0.2.md`](docs/SwiftEffectInference%20Design%20v0.2.md). The inference engines are being lifted from [SwiftProjectLint](https://github.com/Joseph-Cursio/SwiftProjectLint) per the migration plan in §10.

## Three primitives

- **`EffectAnnotationParser`** — read declared effects from `/// @lint.effect …` doc-comment grammar **and** [`swiftidempotency`](https://github.com/Joseph-Cursio/swiftidempotency)'s attribute grammar (`@Pure`, `@Idempotent`, `@NonIdempotent`, `@Observational`, `@ExternallyIdempotent(by:)`). Recognized attribute names are configurable. The doc-comment-only `/// @lint.effect transactional_idempotent` tier (parallel to `externallyIdempotent` in SwiftIdempotency's non-linear lattice) is *recognized* but conservatively projected onto `non_idempotent` to keep this lattice linear — see the decision note on `Effect`.
- **`CallSiteEffectInferrer`** — classify call expressions by callee name + the file's imports. Framework-gated detection for FluentKit, Hummingbird, Vapor, AWSLambdaRuntime, and TCA; receiver-shape rules; CamelCase verb-prefix matching; stdlib-collection exclusion.
- **`BodyEffectInferrer`** — body-based call-graph inference; computes the lub of direct callees' effects with depth tracking. Closure boundaries (`Task { }`, `withTaskGroup`, `Task.detached`, SwiftUI `.task { }`) are not recursed into.

A unified **`EffectSymbolTable`** resolves declared and inferred effects with collision-withdrawal semantics.

## Consumers (today)

- **[SwiftProjectLint](https://github.com/Joseph-Cursio/SwiftProjectLint)** — uses the inferrers to feed lint rule enforcement (violations fire when annotated functions call functions at odds with declared effects).
- **[SwiftInferProperties](https://github.com/Joseph-Cursio/SwiftInferProperties)** — uses the inferrers to surface "this function looks idempotent — consider annotating it" suggestions for human review.

The annotation grammars themselves are emitted by **[swiftidempotency](https://github.com/Joseph-Cursio/swiftidempotency)** (no inference dependency — it's a one-way producer).

## Build & test

```sh
swift package clean && swift test
```

The current skeleton has no behavior; the test target only asserts the namespaces compile. Real engines land in migration step 3 (lift code from SPL with the renames per Q1).

## License

MIT — see [LICENSE](LICENSE).
