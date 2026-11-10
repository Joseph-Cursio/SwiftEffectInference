// MARK: - Idempotent receiver/method pairs (framework-gated)

extension FrameworkGates {

    /// Idempotent `(receiver, method)` pairs — used when the method
    /// name alone is too ambiguous to whitelist but the combination
    /// is a specific framework idiom. Nested dictionary keyed by
    /// method first (matching the inferrer's lookup pattern) then
    /// by receiver name.
    ///
    /// Hummingbird's `request.decode(...)` and `parameters.require(...)`
    /// are the motivating pair. `decode` as a bare method would fire
    /// on any `.decode()` call in a Hummingbird-importing file (the
    /// existing codec-receiver path only matches `decoder` / `encoder`
    /// receivers), and `require` is generic enough to collide with
    /// user-defined validation helpers. Pinning to the specific
    /// framework-canonical receiver name avoids both problems.
    ///
    /// AWSLambdaRuntime's response-writer primitives
    /// (`outputWriter.write(...)`, `responseWriter.write(...)`,
    /// `responseWriter.finish()`) live here for the same reason:
    /// `write` is explicitly excluded from the bare-name whitelist
    /// (see `CallSiteEffectInferrer.nonIdempotentNames` commentary)
    /// because atomic-file / REST-semantics writes are idempotent but
    /// indistinguishable by name alone. The closure-parameter
    /// receiver names (`outputWriter` for `LambdaResponseWriter`,
    /// `responseWriter` for `LambdaResponseStreamWriter`) are the
    /// canonical names in the swift-aws-lambda-runtime v2.x handler
    /// signatures. The Lambda runtime's at-least-once contract
    /// dedup-guards invocation retries at its own boundary, so these
    /// calls are idempotent-in-replay by the runtime contract.
    ///
    /// Hummingbird Router DSL (slot 16) — `router.{get,post,put,patch,delete}`
    /// at route-registration sites. Hummingbird's `Router` exposes one
    /// HTTP-verb method per standard method, each of which registers a
    /// handler closure with the router's internal `TrieRouter`. From the
    /// retry-context lint's perspective these are startup-time registration
    /// calls, not request-scoped operations — annotating a `buildRouter()`
    /// or `addXRoutes(to router:)` helper with `@lint.context replayable`
    /// is a convenience to walk INTO the registered handler closures; the
    /// registration calls themselves should stay silent. Gating on the
    /// bare `router` receiver is the precision mechanism — it keeps the
    /// whitelist from silencing unrelated `.get` / `.post` / `.delete`
    /// methods on non-router receivers in the same file. 2-adopter
    /// evidence: `samalone/prospero` (3× `router.post` Run A + 11×
    /// `router.get` Run B) and
    /// `hummingbird-project/hummingbird-examples/open-telemetry`
    /// (1× `router.post` Run A + 2× `router.get` Run B) — identical
    /// rule-path shapes across both corpora.
    ///
    /// Vapor routing DSL (slot 17) — `app.{get,post,put,patch,delete}`
    /// at route-registration sites. Parallel slice to slot 16 against
    /// Vapor's `Application`. Vapor adopters that bind handlers via
    /// inline trailing closures (`app.get("/path") { req in ... }`)
    /// inside a `func routes(_ app: Application) throws { ... }` helper
    /// annotated `@lint.context replayable` hit the same registration-
    /// site-noise pattern as Hummingbird. Note: `app.get` is silent
    /// under replayable because `get` is idempotent-by-prefix, but
    /// fires under strict_replayable without this entry; whitelisting
    /// all 5 verbs silences across both tiers. 2-adopter evidence:
    /// `kylebshr/luka-vapor` (2× `app.post` Run A + 1× `app.get` Run B)
    /// and `sinduke/HelloVapor` (1× `app.post` Run A + 5× `app.get`
    /// Run B) — identical rule-path shapes across both corpora.
    ///
    /// Hummingbird `queryParameters.get` (slot 18) — structural sibling
    /// to the existing `(parameters, require)` entry. Hummingbird's
    /// `request.uri.queryParameters.get(_:as:)` is a URL-parameter
    /// retrieval-by-name, no more side-effecting than `parameters.get`
    /// (which ships as part of slot 18's cross-framework table below).
    /// 1-adopter evidence (prospero: 1 fire); shipped as a Hummingbird-
    /// gated sibling to keep the parameter-access surface complete.
    ///
    /// Vapor `app.register(collection:)` (slot 21) — Vapor's
    /// `Application.register(collection:)` idiom for mounting a
    /// `RouteCollection` conformer at startup time. Structurally
    /// sibling to the slot-17 `(app, get|post|...)` entries — same
    /// receiver, same gating framework, same "startup-time registration
    /// DSL, not request-scoped" semantics. Ships silent under both
    /// replayable and strict_replayable because `register` is in the
    /// `nonIdempotentNames` server-app-verb lexicon (slot 13), so
    /// without this entry every `app.register(collection:)` in a
    /// `@lint.context replayable`-annotated `routes(_:)` helper
    /// mis-fires on adopters who bind their controllers by collection.
    /// 3-adopter evidence: `sinduke/HelloVapor` (prior 1-adopter),
    /// `uitsmijter/Uitsmijter` (10 sites — `HealthController`,
    /// `VersionsController`, `MetricsController`, `LoginController`,
    /// `LogoutController`, `InterceptorController`,
    /// `WellKnownController`, `AuthorizeController`, `TokenController`,
    /// `RevokeController`), `kphrx/plc-handle-tracker` (2 sites —
    /// `DidController`, `HandleController`).
    ///
    /// Swift Concurrency `Task.sleep` (slot 22) — stdlib
    /// `Task.sleep(nanoseconds:)` / `Task.sleep(for:)` primitive used
    /// in retry-backoff loops, rate-limit pacing, scheduler delays,
    /// and test harnesses. Idempotent by construction — a replay
    /// incurs additional wall-clock latency but no state mutation.
    /// The receiver `Task` is a stdlib type, not a framework module,
    /// so the import gate is satisfied via `alwaysActiveFrameworks`
    /// rather than a literal `import SwiftConcurrency`. Both modern
    /// `Task.sleep(for: .seconds(N))` and legacy
    /// `Task.sleep(nanoseconds: N)` spellings resolve here because the
    /// `(receiver, method)` lookup is name-based, not signature-based.
    /// 4-adopter evidence: `hummingbird-examples/open-telemetry`
    /// (prior 1-adopter), `uitsmijter/Uitsmijter` (5 sites across
    /// Logger, JWT KeyStorage, JavaScriptProvider, EntityCRDLoader),
    /// `JulianKahnert/HomeAutomation` (5 sites across CustomActorSystem,
    /// Timer, WindowOpen), `VernissageApp/VernissageServer` (5+ sites
    /// across ClearAttachmentsService + PurgeStatusesService backoff
    /// loops).
    private static let idempotentReceiverMethodsByFramework: [String: [String: String]] = [
        "decode": ["request": hummingbird],
        "require": ["parameters": hummingbird],
        "write": [
            "outputWriter": awsLambdaRuntime,
            "responseWriter": awsLambdaRuntime,
        ],
        "finish": ["responseWriter": awsLambdaRuntime],
        "get": [
            "router": hummingbird, "app": vapor,
            "queryParameters": hummingbird,
        ],
        "post": ["router": hummingbird, "app": vapor],
        "put": ["router": hummingbird, "app": vapor],
        "patch": ["router": hummingbird, "app": vapor],
        "delete": ["router": hummingbird, "app": vapor],
        "register": ["app": vapor],
        "sleep": ["Task": swiftConcurrency],
    ]

    /// Returns the framework that owns a given idempotent
    /// `(receiver, method)` pair, or nil when the pair isn't listed.
    public static func framework(
        forIdempotentReceiver receiver: String,
        method: String
    ) -> String? {
        idempotentReceiverMethodsByFramework[method]?[receiver]
    }

    // MARK: - Cross-framework idempotent receiver/method pairs (slot 18)

    /// Idempotent `(receiver, method)` pairs where the receiver
    /// identifier is common convention across multiple web frameworks.
    /// Consulted *after* `idempotentReceiverMethodsByFramework` so the
    /// framework-specific table (where the receiver name is
    /// framework-canonical) takes precedence.
    ///
    /// `parameters.get` (slot 18) is the motivating pair: both
    /// Hummingbird (`context.parameters.get(_:as:)`) and Vapor
    /// (`req.parameters.get("name")`) expose a `parameters` accessor
    /// on their request object with a `.get(_:)` method that retrieves
    /// URL path parameters by name. Retrieval is a pure-read — same
    /// URL produces same value — so silencing is both safe and
    /// precision-preserving. The receiver identifier `parameters` is
    /// specific enough in the web-framework-imported context that
    /// misattribution to user-defined `parameters` variables is
    /// unlikely.
    ///
    /// 2-adopter cross-framework evidence:
    /// `samalone/prospero` (4× `context.parameters.get`, Hummingbird)
    /// and `sinduke/HelloVapor` (1× `req.parameters.get("name")`,
    /// Vapor) — 5 fires silenced across 2 independent adopters,
    /// different frameworks, identical receiver-method shape.
    private static let idempotentReceiverMethodsMultiFramework: [String: [String: Set<String>]] = [
        "get": [
            "parameters": [hummingbird, vapor]
        ],
    ]

    /// Returns the set of frameworks any of which qualifies a given
    /// idempotent `(receiver, method)` pair as idempotent, or nil when
    /// the pair isn't listed in the multi-framework table. The caller
    /// is responsible for checking whether any of the returned
    /// frameworks is active in the current file's import set.
    public static func frameworks(
        forCrossFrameworkIdempotentReceiver receiver: String,
        method: String
    ) -> Set<String>? {
        idempotentReceiverMethodsMultiFramework[method]?[receiver]
    }
}
