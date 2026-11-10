@testable import SwiftEffectInference
import SwiftParser
import SwiftSyntax

struct MissingFunction: Error, CustomStringConvertible {
    let name: String
    var description: String { "no func \(name)" }
}

/// Finds the first function declared with a given name.
private final class NamedFunctionFinder: SyntaxVisitor {
    let name: String
    var found: FunctionDeclSyntax?

    init(name: String) {
        self.name = name
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if found == nil, node.name.text == name { found = node }
        return .visitChildren
    }
}

/// The construction-purity helpers, for any suite that judges construction. A suite opts in by
/// conforming; its tests then call `constructionRefuted(_:in:)` and `constructionRefutation(of:in:)`
/// directly.
protocol ConstructionTesting {}

extension ConstructionTesting {
    /// The configured verdict on the first function named `name`, judged against facts built from
    /// every one of `sources` — several when the snippet spans files or modules.
    func constructionRefutation(of name: String, in sources: [String]) throws -> PurityRefutation? {
        let trees = sources.map { Parser.parse(source: $0) }
        let facts = ConstructionFacts.build(from: trees)
        let finder = NamedFunctionFinder(name: name)
        for tree in trees where finder.found == nil { finder.walk(tree) }
        guard let function = finder.found else { throw MissingFunction(name: name) }
        return PurityInferrer(constructionFacts: facts).refutation(for: function)
    }

    /// Whether constructing anything in `name` refutes it.
    func constructionRefuted(_ name: String, in sources: String...) throws -> Bool {
        try constructionRefutation(of: name, in: sources) != nil
    }
}
