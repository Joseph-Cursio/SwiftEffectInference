import SwiftSyntax

/// Collects the set of top-level module imports declared in a source file.
///
/// Used by `CallSiteEffectInferrer` to gate framework-specific whitelists
/// by import presence: a `JSONDecoder()` call classifies as
/// Foundation-idempotent only when the enclosing file actually has
/// `import Foundation`. Without this gate, a user-defined
/// `class JSONDecoder` in an adopter module with no Foundation import
/// would silently classify as observational, producing a quiet false
/// negative.
///
/// ## Supported import shapes
///
///   - `import Foundation` → `["Foundation"]`
///   - `import Foundation.NSJSONSerialization` → `["Foundation"]`
///     (base-module only)
///   - `@preconcurrency import Foundation` → `["Foundation"]`
///   - `@_implementationOnly import Foundation` → `["Foundation"]`
///   - `import class Foundation.JSONDecoder` → `["Foundation"]`
///   - `#if canImport(Foundation) \n import Foundation \n #endif` →
///     `["Foundation"]` when the branch is source-accurate
///
/// All variants collapse to the base module name. Tests and production
/// use the base-module set; the inferrer never inspects sub-path details.
public enum ImportCollector {

    /// Returns the set of base module names imported at file scope in
    /// `source`. Nested or conditional imports under `#if` evaluate
    /// source-accurately — every syntactically-present `import`
    /// contributes, regardless of whether the `#if` condition is
    /// statically true. Conservative by design: under-including imports
    /// could produce false-positive classifications in gated code.
    public static func imports(in source: SourceFileSyntax) -> Set<String> {
        let visitor = ImportVisitor(viewMode: .sourceAccurate)
        visitor.walk(source)
        return visitor.modules
    }
}

private final class ImportVisitor: SyntaxVisitor {
    var modules: Set<String> = []

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        // `node.path` is an `ImportPathComponentListSyntax` — a dotted
        // chain like `Foundation.NSJSONSerialization`. Take the first
        // component as the base module name.
        if let first = node.path.first?.name.text, !first.isEmpty {
            modules.insert(first)
        }
        return .skipChildren
    }
}
