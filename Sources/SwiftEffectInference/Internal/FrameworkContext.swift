/// Combines file-level imports and project-level config into an
/// "is this framework's whitelist active right now?" predicate. Used by
/// `CallSiteEffectInferrer` to gate per-framework classifications.
///
/// ## Semantics
///
/// `imports` is the **concrete** set of base module names the enclosing
/// source file imports (see `ImportCollector.imports(in:)`). An empty
/// set means "no framework-gated whitelists fire" — synthetic fixtures
/// without imports and adopter files that simply don't use a given
/// framework behave identically. Callers that want to bypass the gate
/// must supply the relevant framework name explicitly.
///
/// When `enabledFrameworks` is `nil`, treat every framework as enabled —
/// the default when a project hasn't set `enabled_framework_whitelists`
/// in its `.swiftprojectlint.yml`. A non-nil value restricts
/// classification to the listed frameworks.
///
/// Both the import gate and the config gate must be active for the
/// whitelist to fire.
public struct FrameworkContext: Sendable {
    public let imports: Set<String>
    public let enabled: Set<String>?

    public init(imports: Set<String>, enabled: Set<String>?) {
        self.imports = imports
        self.enabled = enabled
    }

    public func isFrameworkActive(_ framework: String) -> Bool {
        let enabledOK = enabled?.contains(framework) ?? true
        // Stdlib / built-in frameworks (slot 22: SwiftConcurrency) bypass
        // the import gate — adopter code doesn't typically write
        // `import SwiftConcurrency` because there's no such module.
        // Config opt-out still applies.
        if FrameworkGates.alwaysActiveFrameworks.contains(framework) {
            return enabledOK
        }
        let aliases = FrameworkGates.importAliases(forFramework: framework)
        let importOK = imports.contains(framework) || !aliases.isDisjoint(with: imports)
        return importOK && enabledOK
    }
}
