/// Curated framework-gating data for `CallSiteEffectInferrer`. Lifted from
/// SwiftProjectLint in migration step 3. Single shared list per design v0.2
/// Q6 — both consumers benefit; re-evaluate at ~50 entries.
///
/// Will hold:
/// - FluentKit: `save`/`delete`/`update` (non-idempotent), `query`/`all`/
///   `first`/`filter` (idempotent)
/// - HttpPipeline: `writeStatus`/`respond` (idempotent)
/// - Hummingbird: `request.decode(...)`, `parameters.require(...)`
/// - AWSLambdaRuntime: `outputWriter.write`, `responseWriter.write`,
///   `responseWriter.finish`
/// - Vapor: `parameters.get`
/// - TCA: `Send<Action>.send` (idempotent override inside effect closures)
/// - Foundation codecs: `decode`/`encode` (idempotent when receiver name
///   contains "Decoder"/"Encoder")
package enum FrameworkGates {}
