# SwiftEffectInference — Design Document

**Version:** 0.2
**Status:** Decisions logged; ready for migration step 2 (initialize repo + Package.swift)
**Audience:** Joseph-Cursio (sole maintainer of all consuming projects)
**Consumers (today):** `SwiftProjectLint` (rule enforcement), `SwiftInferProperties` (suggestion generation)
**Annotations source:** `swiftidempotency` (macro emitter, no inference dep)
**Supersedes:** v0.1 (in this same `docs/` directory's git history once committed)

> **What changed v0.1 → v0.2.** All six §11 open questions resolved. Rename adopted (`Effect` / `CallSiteEffectInferrer` / `BodyEffectInferrer` replace SPL's `DeclaredEffect` / `HeuristicEffectInferrer` / `UpwardEffectInferrer`). Annotation parser API kept simple (no `EffectAnnotationContext` value type). Recognized-attribute-names made configurable on the parser. Repo name and visibility confirmed (`Joseph-Cursio/SwiftEffectInference`, public). Initial-version policy confirmed (un-tagged through migration, tag 0.1.0 once both consumers stabilize). Framework-gate lists ship as a single shared list. §11 converted from "Open Questions" to "Decisions Log."

---

## 1. Purpose

A shared, reusable static-analysis library that classifies Swift functions and call sites by their **side-effect character** along a four-tier lattice:

```
observational < idempotent < externally_idempotent < non_idempotent
```

The library performs three jobs and exposes them as composable primitives:

1. **Parse** declared effects from doc-comment grammar (`/// @lint.effect ...`) and from `swiftidempotency`'s attribute grammar (`@Idempotent`, `@NonIdempotent`, `@Observational`, `@ExternallyIdempotent(by:)`).
2. **Infer** effects for un-annotated code via two complementary engines: a name/framework-based call-site classifier (`CallSiteEffectInferrer`) and a body-based call-graph traversal that computes the least-upper-bound of callees' effects (`BodyEffectInferrer`).
3. **Resolve** declared and inferred effects through a unified symbol table (`EffectSymbolTable`) with collision-withdrawal semantics.

Consumers compose these primitives for different purposes: SwiftProjectLint flags violations of declared contracts; SwiftInferProperties surfaces "this function looks idempotent — consider annotating" suggestions.

---

## 2. Why Extract from SwiftProjectLint?

SwiftProjectLint currently owns these engines as private types in
`Packages/SwiftProjectLintVisitors/`. SwiftInferProperties needs the same logic for its idempotence-candidate detection (PRD §4.1's effect-tier counter-signals; the just-shipped M1.2 `NonDeterministicAPIs` is a thin stand-in for what these engines do). Three options were considered:

| Option | Approach | Trade |
|---|---|---|
| (a) Hard dep on SPL | SwiftInfer imports `SwiftProjectLintVisitors` directly | Fastest. Couples SwiftInfer's stability to SPL's churn. |
| (b) Independent re-implementation | SwiftInfer ships its own lightweight inference | Cleanest decoupling. Duplicated logic; quality drift between consumers. |
| (c) **Extract a shared core** | Both SPL and SwiftInfer depend on `SwiftEffectInference` | Highest setup cost. Cleanest long-term. Only viable because one maintainer owns both repos and can sequence the migration. |

Decision (per the M1 design conversation 2026-04-30): **(c)**.

---

## 3. Scope — In

The shared core ships exactly the inference primitives. Consumers compose them for their own purposes; the core has no opinion on how the results are used.

| Component | Responsibility | Origin |
|---|---|---|
| `Effect` enum | Four-tier lattice (`observational` / `idempotent` / `externallyIdempotent` / `nonIdempotent`) + lub | Renamed from SPL's `DeclaredEffect` |
| `EffectAnnotationParser` | Read `/// @lint.effect ...` doc-comment grammar **and** `@Idempotent` / `@NonIdempotent` / `@Observational` / `@ExternallyIdempotent(by:)` attribute grammar; recognized attribute name set is **configurable** | Lifted from SPL |
| `CallSiteEffectInferrer` | Call-site classification by name + framework gating (FluentKit, Hummingbird, Vapor, AWSLambdaRuntime) + receiver-shape rules + CamelCase verb-prefix detection + stdlib-collection exclusion | Lifted from SPL (~538 lines, renamed from `HeuristicEffectInferrer`) |
| `BodyEffectInferrer` | Body-based call-graph inference; computes lub of direct callees' effects with depth tracking; closure-boundary enforcement (skips `Task { }`, `withTaskGroup`, `Task.detached`, SwiftUI `.task { }`) | Lifted from SPL (~276 lines, renamed from `UpwardEffectInferrer`) |
| `EffectSymbolTable` | Cross-file declared+inferred effect lookup; collision-withdrawal policy when annotated declarations of the same signature disagree | Lifted from SPL |
| Framework-gate data | Curated lists: idempotent stdlib mutations (Array.append/remove etc.), framework idempotent/non-idempotent method gates, observational receiver-shape patterns | Lifted from SPL — single shared list (Q6) |

---

## 4. Scope — Out

Things that **stay in their current home**:

- **Rule definitions, violation reporting, severity levels, lint diagnostics** — stay in SPL.
- **Macro implementations** (`@Idempotent` etc.) — stay in `swiftidempotency`. The shared core *parses* the attributes but does not *define* them.
- **Test generation** (`@IdempotencyTests`, `#assertIdempotent`) — stay in `swiftidempotency`.
- **Algebraic-structure detection** (round-trip, commutativity, associativity, monoid, group, ring) — stay in SwiftInferProperties.
- **TestLifter** — stays in SwiftInferProperties.
- **CLI tools, GUI apps** — stay in SPL / SwiftInferProperties as before.

---

## 5. Public API Surface

```swift
// Effect.swift
public enum Effect: Hashable, Sendable, Comparable {
    case observational
    case idempotent
    case externallyIdempotent(keyParameter: String?)
    case nonIdempotent

    /// Lattice least-upper-bound. `.observational ⊔ .idempotent == .idempotent`,
    /// `.idempotent ⊔ .nonIdempotent == .nonIdempotent`, etc.
    public func lub(_ other: Effect) -> Effect
}

// EffectAnnotationParser.swift
public struct EffectAnnotationParser: Sendable {

    /// The set of attribute names this parser recognizes as effect markers,
    /// keyed by macro name. Default matches `swiftidempotency`'s shipped set
    /// at the time this core was tagged. Override when the upstream macro
    /// surface changes or when integrating a project-specific marker family.
    public struct AttributeRecognition: Sendable {
        public let idempotent: Set<String>           // default: ["Idempotent"]
        public let nonIdempotent: Set<String>        // default: ["NonIdempotent"]
        public let observational: Set<String>        // default: ["Observational"]
        public let externallyIdempotent: Set<String> // default: ["ExternallyIdempotent"]

        public static let `default` = AttributeRecognition(
            idempotent: ["Idempotent"],
            nonIdempotent: ["NonIdempotent"],
            observational: ["Observational"],
            externallyIdempotent: ["ExternallyIdempotent"]
        )
    }

    public init(recognition: AttributeRecognition = .default)

    /// Parse declared effects from a function declaration's leading trivia
    /// (doc comments) and attribute list. Returns `nil` when no annotation
    /// is present. Throws on grammar errors.
    public func parse(
        attributes: AttributeListSyntax,
        leadingTrivia: Trivia
    ) throws -> Effect?
}

// CallSiteEffectInferrer.swift
public enum CallSiteEffectInferrer {

    /// Classify a call expression by its callee's name + the file's imports.
    /// Returns `nil` when no heuristic applies (deliberately tight whitelist).
    public static func infer(
        call: FunctionCallExprSyntax,
        importedFrameworks: Set<String>
    ) -> Effect?

    /// Diagnostic prose explaining which heuristic fired (consumed by SPL
    /// for violation messages, by SwiftInfer for explainability blocks).
    public static func inferenceReason(
        call: FunctionCallExprSyntax,
        importedFrameworks: Set<String>
    ) -> String?
}

// BodyEffectInferrer.swift
public struct BodyInference: Sendable {
    public let effect: Effect
    public let depth: Int  // longest unannotated-chain back to a declared anchor
}

public enum BodyEffectInferrer {

    /// Infer effects for un-annotated functions by computing the lub of
    /// their direct callees' effects. `resolveCalleeEffect` is the consumer-
    /// supplied lookup function — typically backed by `EffectSymbolTable`.
    public static func inferEffects(
        in source: SourceFileSyntax,
        resolveCalleeEffect: (String) -> Effect?
    ) -> [String: BodyInference]

    /// Multi-hop variant: iterates to fixed-point. Use when chains of
    /// un-annotated callees matter.
    public static func inferEffectsMultiHop(
        in source: SourceFileSyntax,
        resolveCalleeEffect: (String) -> Effect?
    ) -> [String: BodyInference]
}

// EffectSymbolTable.swift
public final class EffectSymbolTable {
    public init()
    public func register(declaration: FunctionDeclSyntax, declared: Effect?)
    public func registerInferred(name: String, inference: BodyInference)
    public func lookup(name: String) -> Effect?
    /// Lookup with provenance for diagnostic prose.
    public func lookupWithProvenance(name: String) -> (Effect, EffectProvenance)?
}

public enum EffectProvenance: Sendable {
    case declared
    case bodyInferred(depth: Int)
    case callSite(reason: String)
}
```

`package`-visible helpers (framework-gate tables, parser internals) live alongside the public types but are not part of the consumer-facing surface.

---

## 6. Annotation Grammars Supported

Both grammars must be supported on day one — bilingual parser.

**Doc-comment form** (SPL's authored convention):
```swift
/// @lint.effect idempotent
/// @lint.context replayable
func step(_ event: Event) -> State { ... }
```

**Attribute form** (`swiftidempotency`'s macros, default `AttributeRecognition`):
```swift
@Idempotent
func step(_ event: Event) -> State { ... }

@ExternallyIdempotent(by: "idempotencyKey")
func charge(amount: Int, idempotencyKey: IdempotencyKey) -> Receipt { ... }
```

Both compile down to the same `Effect` value. The parser handles disagreement on the same declaration as a **collision-withdrawal** (lookup returns `nil`) — same policy as today's SPL.

The `@lint.context` doc-comment grammar (`replayable`, `retry_safe`, `strict_replayable`, `once`) is SPL-specific concern (it gates which rules fire) and is **out of scope** for the shared core. SPL keeps that parsing internal.

**Attribute recognition is configurable** (per Q3 decision). A consumer integrating a project-specific marker family — say a `@RetryIdempotent` attribute the team adopted before swiftidempotency stabilized — passes a custom `AttributeRecognition` value to `EffectAnnotationParser.init`. The default matches swiftidempotency's shipped set at the time SwiftEffectInference is tagged; consumers can extend the recognized names without forking the parser.

---

## 7. Lattice and lub Semantics

Identical to SPL today:

```
observational ⊔ x = x
idempotent ⊔ idempotent = idempotent
idempotent ⊔ externallyIdempotent = externallyIdempotent
idempotent ⊔ nonIdempotent = nonIdempotent
externallyIdempotent ⊔ nonIdempotent = nonIdempotent
x ⊔ y where x ≥ y = x   (commutative)
```

`Effect: Comparable` orders by lattice position so `max(a, b)` is the lub.

---

## 8. Dependency Policy

- **`swift-syntax`** is the only required dep. Pin `from: "600.0.0"` to match SPL and SwiftInfer.
- **No `swift-testing` in the library target** (avoids the `Testing.framework` runtime issue SwiftInfer hit in M1.1; the `swift-property-based`-via-SPL pattern is exactly what we're avoiding). Test target uses `Testing` — that's fine, test-target only.
- **No SPL-specific or SwiftInfer-specific types**, including `Severity`, `Diagnostic`, etc. The core returns plain values; consumers attach their own diagnostic types.
- **No `swiftidempotency` dep**, even though we parse its attribute grammar — we recognize the names by string, not by type. swiftidempotency stays an upstream emitter with no shared dependency.

---

## 9. Repository Layout

```
SwiftEffectInference/
├── Package.swift                         # tools 6.1, single library product
├── README.md
├── docs/
│   └── SwiftEffectInference Design v0.2.md   # this file
├── Sources/SwiftEffectInference/
│   ├── Effect.swift                      # enum + lattice + lub
│   ├── EffectAnnotationParser.swift      # bilingual grammar (configurable recognition)
│   ├── CallSiteEffectInferrer.swift      # call-site classification
│   ├── BodyEffectInferrer.swift          # body-based inference
│   ├── EffectSymbolTable.swift           # cross-file lookup
│   └── Internal/                         # package-visible helpers
│       ├── FrameworkGates.swift          # FluentKit / Hummingbird / Vapor / AWSLambdaRuntime gate data
│       ├── ReceiverShapes.swift          # logger / metric receiver patterns
│       └── StdlibIdempotentMutations.swift  # Array.append, Set.insert, Dictionary.updateValue, ...
└── Tests/SwiftEffectInferenceTests/
    ├── EffectLatticeTests.swift
    ├── EffectAnnotationParserTests.swift
    ├── CallSiteEffectInferrerTests.swift
    ├── BodyEffectInferrerTests.swift
    └── EffectSymbolTableTests.swift
```

Single library product `SwiftEffectInference`. No executable; this is a library only. Repo: `Joseph-Cursio/SwiftEffectInference`, public from day one (Q4).

---

## 10. Migration Plan

Sequencing identical to the M1 conversation (2026-04-30):

1. ✅ **Sign off on this design doc** — done as of v0.2.
2. **Initialize `Joseph-Cursio/SwiftEffectInference`** — `Package.swift`, this design doc, README, empty `Sources/` skeleton. CI from the SwiftInfer template.
3. **Lift code from SPL into the new repo.** Apply renames per Q1 (`DeclaredEffect` → `Effect`, `HeuristicEffectInferrer` → `CallSiteEffectInferrer`, `UpwardEffectInferrer` → `BodyEffectInferrer`). Make `EffectAnnotationParser`'s recognized attribute names configurable per Q3. Port tests. Verify the new repo's tests are green standalone.
4. **Update SwiftProjectLint** to depend on `SwiftEffectInference` (initially via local path to match SPL/SwiftInfer's pre-1.0 convention). Delete the moved files from `Packages/SwiftProjectLintVisitors/`. Replace internal type imports — note SPL's existing call sites refer to the old names (`HeuristicEffectInferrer.infer(...)`, etc.), so this step *is* the rename rollout for SPL. Verify the full SPL test suite stays green.
5. **Tag a SwiftProjectLint minor release** to anchor the migration.
6. **Update SwiftInferProperties' `Package.swift`** to depend on `SwiftEffectInference` (local path). Replace M1.2's `NonDeterministicAPIs` curated list with `CallSiteEffectInferrer` calls. Decide whether `BodySignals.hasNonDeterministicCall` survives as a derived projection or gets replaced with `BodySignals.inferredEffect: Effect`.
7. **Tag SwiftEffectInference 0.1.0** (per Q5 — un-tagged through migration, tag once both consumers stabilize on the API).
8. **Resume SwiftInfer M1** — M1.3 reordered to round-trip + cross-function pairing; idempotence template either dropped or deferred to a milestone informed by the new core.

Estimated ~4–5 working sessions across two repos. Each step gates the next; any breakage in (4) blocks (6).

---

## 11. Decisions Log

All six v0.1 open questions resolved 2026-04-30.

### Q1. Naming. → **Rename adopted.**
Public API names: `Effect`, `CallSiteEffectInferrer`, `BodyEffectInferrer`. Old SPL names (`DeclaredEffect`, `HeuristicEffectInferrer`, `UpwardEffectInferrer`) do not survive the lift — migration step 4 rolls the renames into SPL's call sites in the same change that switches SPL to the new dep.

Rationale: the new names describe what each engine does (classify call sites by name vs. analyze function bodies) without requiring the reader to know SPL's internal vocabulary. The disruption is one-time (a single SPL PR); the clarity benefit is permanent.

### Q2. `EffectAnnotationContext` design. → **Keep simple.**
The parser API stays at `(attributes: AttributeListSyntax, leadingTrivia: Trivia) -> Effect?`. No `EffectAnnotationContext` value type. The symbol table's collision-withdrawal logic stays internal to `EffectSymbolTable`.

Rationale: the simpler API covers both consumers' needs. Revisit only if a third consumer needs to surface intermediate context.

### Q3. `swiftidempotency` macro-name coupling. → **Make configurable.**
`EffectAnnotationParser.init(recognition:)` takes an `AttributeRecognition` struct. The default value matches swiftidempotency's shipped set; consumers can extend it for project-specific markers. See §5 and §6 for the API.

Rationale: tiny API addition, future-proofs against swiftidempotency rename or third-party adoption of the inference engines under a different attribute family.

### Q4. Repository name and visibility. → **`Joseph-Cursio/SwiftEffectInference`, public from day one.**

### Q5. Initial version. → **Un-tagged through migration; tag 0.1.0 after step 6.**
Local-path deps from SPL and SwiftInfer during the migration window. Tag once SPL successfully consumes the new core (step 4) and SwiftInfer's `Package.swift` swap (step 6) is green. That tag becomes the minimum version dependents pin against once any of the three projects ships a 1.0.

### Q6. Framework-gate lists. → **Single shared list, ship as one module.**
The curated FluentKit / Hummingbird / Vapor / AWSLambdaRuntime / TCA / receiver-shape data lives in `Sources/SwiftEffectInference/Internal/FrameworkGates.swift` (and siblings). Both consumers benefit; neither has to re-curate.

Re-evaluate at ~50 framework entries: if the list grows past that threshold, split into `SwiftEffectInferenceFrameworks` opt-in modules (deferred decision).

---

## 12. Non-decisions (deliberate)

Things this document does not commit to and that the v0.1 implementation will not handle:

- **Type-based inference.** Heuristic + body inference both work from syntax. No type resolution, no protocol-conformance lookup, no generic substitution. This matches SPL's current scope.
- **Pure tier.** SPL's design notes mention `pure` as an aspirational fifth tier (functions with no side effects at all). Out of scope for v0.1.
- **YAML override of inference whitelists.** SPL plans this; v0.1 of the shared core does not.
- **Multi-pass call-graph fixed-point as default.** Single-pass / one-hop stays the default; multi-hop is opt-in via the `inferEffectsMultiHop` API.
- **Macro implementations.** The core never *defines* `@Idempotent` etc. — only *recognizes* them.

---

## 13. References

- SwiftInferProperties PRD v0.3 — `Joseph-Cursio/SwiftInferProperties/docs/SwiftInferProperties PRD v0.3.md` §4.1 (effect-tier counter-signals), §10 (architectural responsibility table).
- SwiftProjectLint — `Joseph-Cursio/SwiftProjectLint/Packages/SwiftProjectLintVisitors/` (current home of the engines being lifted; renamed during migration step 4).
- swiftidempotency — `Joseph-Cursio/swiftidempotency/Sources/SwiftIdempotency/Attributes.swift` (the attribute grammar this core parses by default).
- 2026-04-30 conversation log — option-(c) decision rationale and §11 sign-off.
