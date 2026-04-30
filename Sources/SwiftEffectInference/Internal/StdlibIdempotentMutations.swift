/// Curated `(receiver, method)` pairs that are idempotent stdlib mutations
/// despite carrying non-idempotent-suggesting names. Used by
/// `CallSiteEffectInferrer` to suppress bare-name false positives. Lifted
/// from SwiftProjectLint in migration step 3.
///
/// Will hold:
/// - `Array.append`, `Array.insert`, `Array.remove*`
/// - `Set.insert`, `Set.remove`, `Set.removeAll`
/// - `Dictionary.updateValue`, `Dictionary.removeValue`
package enum StdlibIdempotentMutations {}
