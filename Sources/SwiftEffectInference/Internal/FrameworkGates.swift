import Foundation

/// Per-framework grouping of the `CallSiteEffectInferrer` whitelists.
///
/// Round 14 split the previously-monolithic `idempotentFrameworkTypes`
/// (PR #9) into per-framework groups so the inferrer can gate each group
/// by `import` presence in the file under analysis. Without this gate, a
/// user-defined `class Counter` in an adopter module with no `import
/// Metrics` would classify as observational just because the name matched
/// swift-metrics' `Counter`.
///
/// Gating is enforced in `CallSiteEffectInferrer` via
/// `FrameworkContext`, which combines:
///   - `imports` — the set of module names imported in the current file
///   - `enabledFrameworks` — per-project config override
///
/// Both are optional; when nil, the inferrer falls back to the pre-round-
/// 14 "apply every whitelist by name" behaviour for test backwards
/// compatibility.
public enum FrameworkGates {

    // MARK: - Framework names (opaque strings — used as dictionary keys)

    /// Apple's Foundation framework.
    public static let foundation = "Foundation"
    /// SwiftNIO's core module, `NIOCore` (apple/swift-nio).
    public static let nio = "NIOCore"
    /// The `AWSLambdaEvents` module (swift-server/swift-aws-lambda-events).
    public static let awsLambdaEvents = "AWSLambdaEvents"
    /// SwiftLog's `Logging` module (apple/swift-log).
    public static let logging = "Logging"
    /// Apple's `os` module — unified logging (`Logger`, `os_log`).
    public static let osLog = "os"
    /// Swift Metrics' `Metrics` module (apple/swift-metrics).
    public static let metrics = "Metrics"
    /// Vapor's Fluent ORM core, `FluentKit`; importing the `Fluent` meta-package also opens this gate.
    public static let fluent = "FluentKit"
    /// The Hummingbird web framework (hummingbird-project/hummingbird).
    public static let hummingbird = "Hummingbird"
    /// The Composable Architecture (pointfreeco/swift-composable-architecture).
    public static let composableArchitecture = "ComposableArchitecture"
    /// The `AWSLambdaRuntime` module (swift-server/swift-aws-lambda-runtime).
    public static let awsLambdaRuntime = "AWSLambdaRuntime"
    /// The `HttpPipeline` module of pointfreeco/swift-web.
    public static let httpPipeline = "HttpPipeline"
    /// The Vapor web framework (vapor/vapor).
    public static let vapor = "Vapor"
    /// Swift's built-in concurrency (`Task`, actors, `AsyncStream`); not a real module, so always active.
    public static let swiftConcurrency = "SwiftConcurrency"

    /// Every framework this project recognises. Order-insensitive.
    /// Used as the default `enabledFrameworks` set when a project
    /// hasn't opted out of any framework's classifications.
    public static let knownFrameworks: Set<String> = [
        foundation, nio, awsLambdaEvents, logging, osLog, metrics, fluent,
        hummingbird, composableArchitecture, awsLambdaRuntime, httpPipeline,
        vapor, swiftConcurrency,
    ]

    // MARK: - Always-active (stdlib / built-in) frameworks

    /// Frameworks whose "import presence" gate is always satisfied
    /// because their types are part of Swift's stdlib or a built-in
    /// runtime and no `import` declaration is typically required.
    ///
    /// The `swiftConcurrency` framework name (slot 22) is the
    /// motivating case: `Task`, `async`, `await`, `AsyncStream`,
    /// `Actor`, etc. are in stdlib; adopter code never writes `import
    /// SwiftConcurrency` because there's no such module. The
    /// `FrameworkContext.isFrameworkActive` gate short-circuits to
    /// `true` for these names (modulo the config opt-out), so entries
    /// for `(Task, sleep)` etc. in `idempotentReceiverMethodsByFramework`
    /// still go through the standard lookup path rather than needing
    /// a parallel stdlib-specific table.
    ///
    /// The config opt-out still applies — a project can set
    /// `enabled_framework_whitelists: [...]` excluding `SwiftConcurrency`
    /// to restore pre-slot-22 behaviour.
    public static let alwaysActiveFrameworks: Set<String> = [
        swiftConcurrency
    ]

    // MARK: - Import aliases (re-export / meta-package handling)

    /// Alternate module names that, when imported, qualify as having
    /// imported the canonical framework. Idiomatic adopter code often
    /// imports a meta-package that re-exports the concrete module — the
    /// linter sees the literal import name, so without an alias table
    /// the framework-gated whitelist silently doesn't fire.
    ///
    /// Slot 19 motivating case: Vapor's `Fluent` meta-package
    /// (`vapor/fluent`) re-exports `FluentKit`, `FluentSQL`, `FluentSQLiteDriver`
    /// etc. Idiomatic Vapor code imports `Fluent`, not `FluentKit`. The
    /// linter's FluentKit gate was matching the literal module name, so
    /// `save()` / query-builder reads on `import Fluent` adopters were
    /// going unclassified. Evidence from the hellovapor package trial:
    /// a `save(on:)` call inside an `@ExternallyIdempotent`-marked body
    /// under `import Fluent` went silent, then fired the expected
    /// `idempotencyViolation` after swapping to `import FluentKit` —
    /// confirming the gate, not the classification, was the gap.
    ///
    /// Alias sets live alongside the canonical framework name. The
    /// `isFrameworkActive` check consults both the canonical name and
    /// any alias when testing import presence. The canonical name
    /// remains the single identity used throughout — the reason string
    /// still names `FluentKit`, the `enabledFrameworks` config still
    /// opts in/out via the canonical name, nested whitelist tables
    /// still key on canonical. Aliases are purely an import-gate
    /// convenience.
    private static let frameworkImportAliases: [String: Set<String>] = [
        fluent: ["Fluent"]
    ]

    /// Returns the set of alternate import names that satisfy the
    /// import gate for `framework`, or an empty set when the framework
    /// has no aliases. Callers should treat any of these as equivalent
    /// to the canonical framework name when testing the adopter's
    /// import set.
    public static func importAliases(forFramework framework: String) -> Set<String> {
        frameworkImportAliases[framework] ?? []
    }

    // MARK: - Idempotent type constructors (bare-identifier call)

    /// Maps a type-constructor name (as it appears in source) to the
    /// framework it comes from. `JSONDecoder` → `"Foundation"`. Lookup
    /// returns nil for names not on any framework's list.
    private static let idempotentTypesByFramework: [String: String] = [
        // Foundation — pure codec containers + immutable byte containers.
        // Configurable but no shared mutable state; equal inputs → equal outputs.
        "JSONDecoder": foundation,
        "JSONEncoder": foundation,
        "PropertyListDecoder": foundation,
        "PropertyListEncoder": foundation,
        "Data": foundation,

        // SwiftNIO — pure byte buffers and views.
        "ByteBuffer": nio,
        "ByteBufferAllocator": nio,

        // AWS Lambda events — response constructors (build a response
        // value from inputs; no side effects beyond allocation).
        "ALBTargetGroupResponse": awsLambdaEvents,
        "APIGatewayResponse": awsLambdaEvents,
        "APIGatewayV2Response": awsLambdaEvents,

        // Hummingbird — error constructors (value types; throwing them
        // is the control-flow mechanism, but constructing the value
        // is pure).
        "HTTPError": hummingbird,
    ]

    /// Returns the framework that owns a given idempotent type
    /// constructor, or nil when the name isn't on any framework's list.
    public static func framework(forIdempotentTypeConstructor name: String) -> String? {
        idempotentTypesByFramework[name]
    }

    // MARK: - Non-idempotent methods (receiver-based call)

    /// Maps a method name (as it appears in source on the receiver side)
    /// to the framework it comes from. `save` → `"FluentKit"`. Lookup
    /// returns nil for names not on any framework's list.
    ///
    /// Used for verbs that are *universally* non-idempotent inside a
    /// framework but ambiguous enough elsewhere that we don't want them
    /// in the global bare-name whitelist. Fluent's `save`/`update`/`delete`
    /// are the motivating case — called on any `Model`-conforming type
    /// they always hit the database, but `Set.update(with:)` in stdlib
    /// or `cache.save()` on an in-memory store have different semantics.
    /// Gating on `import FluentKit` resolves the ambiguity.
    private static let nonIdempotentMethodsByFramework: [String: String] = [
        "save": fluent,
        "delete": fluent,
    ]

    /// Returns the framework that owns a given non-idempotent method
    /// name, or nil when the name isn't on any framework's list.
    public static func framework(forNonIdempotentMethod name: String) -> String? {
        nonIdempotentMethodsByFramework[name]
    }

    // MARK: - Idempotent methods (framework-gated)

    /// Maps a method name to the framework it belongs to, when the
    /// method is a known read-only / pure operation inside that
    /// framework. Fluent's query-builder reads are the motivating case:
    /// `db`, `query`, `all`, `first`, `filter` are all idempotent when
    /// invoked through FluentKit's `Database` / `QueryBuilder` surface,
    /// but have unrelated (usually also idempotent) senses elsewhere
    /// in Swift. Gating on `import FluentKit` resolves which module
    /// owns the name; the idempotent classification is correct for
    /// either interpretation, so a cross-framework false positive
    /// would only change the *reason* string, not the effect.
    ///
    /// HttpPipeline (slot 14) is the second framework on this table.
    /// `writeStatus`, `respond` etc. are freestanding curried functions
    /// in `pointfreeco/swift-web`'s HttpPipeline module, called via
    /// the `|>` and `>=>` pipe operators — `conn |> writeStatus(.ok)`
    /// reads as `writeStatus(.ok)(conn)`. They mutate `Conn<I, J, A>`
    /// state in a value-typed pipeline (each call returns a new `Conn`),
    /// so re-invocation with the same input yields the same response —
    /// observably idempotent at the response-builder boundary.
    /// 2-adopter evidence: isowords (12 fires) + pointfreeco www
    /// (4 fires) on `writeStatus` alone, plus `respond` shared shape.
    ///
    /// Unlike type-constructor whitelists, these are ordinary
    /// method-call names — they can appear as `.method()` on any
    /// receiver, or bare-style when chained after another call.
    /// The gate therefore does not require a receiver; the import
    /// presence is the load-bearing signal.
    private static let idempotentMethodsByFramework: [String: String] = [
        // FluentKit — query-builder reads.
        "db": fluent,
        "query": fluent,
        "all": fluent,
        "first": fluent,
        "filter": fluent,

        // HttpPipeline — response-pipeline primitives (pointfreeco/swift-web).
        // Both adopters use these via `|>` / `>=>` pipe-forward operators
        // on `Conn` state; each call is a value-typed mutation.
        "writeStatus": httpPipeline,
        "respond": httpPipeline,
    ]

    /// Returns the framework that owns a given idempotent method
    /// name, or nil when the name isn't on any framework's list.
    public static func framework(forIdempotentMethod name: String) -> String? {
        idempotentMethodsByFramework[name]
    }

    // MARK: - Per-framework reason phrasing (for diagnostic strings)

    /// Per-framework noun phrase used in the diagnostic reason string
    /// when a callee resolves through `idempotentMethodsByFramework`.
    /// Default (`"framework primitive"`) is generic and safe for any
    /// framework added without explicit phrasing.
    ///
    /// Existing per-framework phrasings:
    /// - FluentKit: `"query-builder read"` — matches the original
    ///   round-14 wording before slot 14 generalised the table.
    /// - HttpPipeline: `"pipeline primitive"` — accurate for
    ///   response-builder-pattern modules where the same name maps
    ///   to a curried `(Conn) -> Conn` primitive.
    private static let idempotentMethodPhrasingByFramework: [String: String] = [
        fluent: "query-builder read",
        httpPipeline: "pipeline primitive",
    ]

    /// Returns the per-framework noun phrase for the
    /// `idempotentMethodsByFramework` reason string. Falls back to
    /// `"framework primitive"` for any framework without an explicit
    /// override, so adding a new framework to the table doesn't
    /// require touching the inferrer.
    public static func idempotentMethodPhrasing(forFramework framework: String) -> String {
        idempotentMethodPhrasingByFramework[framework] ?? "framework primitive"
    }

    // MARK: - Bare-name overrides of the non-idempotent list (framework-gated)

    /// Bare-name callees that would otherwise hit
    /// `CallSiteEffectInferrer.nonIdempotentNames` but are structurally
    /// safe inside a specific framework's closure-parameter idiom. The
    /// bare-name check is consulted *before* the non-idempotent list so
    /// the framework import wins over the name heuristic.
    ///
    /// TCA's `Send<Action>` is the motivating case. Inside an `Effect`
    /// closure (`.run { send in ... await send(.action) ... }`) the
    /// `send` identifier is a closure parameter — calling it dispatches
    /// an action value through the reducer, which is a pure state
    /// transition, not a mail-sending side effect. The heuristic can't
    /// tell the closure-parameter `send` apart from a receiverless
    /// `mailer.send` by structure alone; the `ComposableArchitecture`
    /// import is the disambiguating signal.
    ///
    /// Precision:
    /// - Receiver must be nil — `mailer.send(.email)` keeps its
    ///   non-idempotent classification even in a TCA-importing file.
    /// - Exact-match only — `sendEmail(...)` still hits the prefix-match
    ///   non-idempotent path; only the literal callee name `send` is
    ///   exempted.
    private static let bareNameIdempotentOverridesByFramework: [String: String] = [
        "send": composableArchitecture
    ]

    /// Returns the framework that owns a given bare-name override, or
    /// nil when the name isn't listed. Callers must additionally check
    /// that the call site has no receiver and that the framework is
    /// active in the current `FrameworkContext`.
    public static func framework(
        forBareNameIdempotentOverride name: String
    ) -> String? {
        bareNameIdempotentOverridesByFramework[name]
    }
}
