import SwiftParser
import SwiftSyntax
@testable import SwiftEffectInference

/// The configured verdict on the first function named `name`, judged against facts built from
/// every one of `sources` — several when the snippet spans files or modules.
func constructionRefutation(of name: String, in sources: [String]) throws -> PurityRefutation? {
    let trees = sources.map { Parser.parse(source: $0) }
    let facts = ConstructionFacts.build(from: trees)
    final class Finder: SyntaxVisitor {
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
    let finder = Finder(name: name)
    for tree in trees where finder.found == nil { finder.walk(tree) }
    guard let function = finder.found else { throw MissingFunction(name: name) }
    return PurityInferrer(constructionFacts: facts).refutation(for: function)
}

/// Whether constructing anything in `name` refutes it.
func constructionRefuted(_ name: String, in sources: String...) throws -> Bool {
    try constructionRefutation(of: name, in: sources) != nil
}

struct MissingFunction: Error, CustomStringConvertible {
    let name: String
    var description: String { "no func \(name)" }
}
