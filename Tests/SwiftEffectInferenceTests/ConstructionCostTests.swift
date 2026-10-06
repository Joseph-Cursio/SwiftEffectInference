import Foundation
import SwiftParser
@testable import SwiftEffectInference
import SwiftSyntax
import Testing

/// What building and consulting `ConstructionFacts` costs, on the shapes that once made it cost
/// too much — each pinned by its answer as well as its time, so a fix that changed the answer
/// would fail here too.
///
/// **The budgets are generous on purpose.** Each reproducer took tens of seconds before its fix
/// and takes well under one after, on a debug build; the bound sits far from both, so it fails on
/// the regression and on no machine CI runs on. `.timeLimit` is the backstop for a regression that
/// would not finish at all.
@Suite("ConstructionFacts — cost budget")
struct ConstructionCostTests {

    /// swift-collections' `OrderedDictionary.Elements.SubSequence` declares `typealias SubSequence =
    /// Self`. `SubSequence.Index`, read through it, is `Outer.SubSequence.Index`; with no such type,
    /// the module-like head is dropped — and that is `SubSequence.Index` again, with the depth
    /// bound started afresh by `Self`. It recursed until the stack ran out: a package with that
    /// alias and any refutation crashed the build, and any judgement after it.
    @Test("a lookup that comes back to itself ends, and what else it reached still counts", .timeLimit(.minutes(1)))
    func lookupThatComesBackToItselfEnds() throws {
        let loop = """
        enum Outer {}
        extension Outer { struct SubSequence {} }
        extension Outer.SubSequence { typealias SubSequence = Self }
        struct Marker { let id = UUID() }
        func make() -> Any { SubSequence.Index() }
        """
        #expect(try constructionRefuted("make", in: loop) == false)

        let elsewhere = """
        struct Other { struct Index { let id = UUID() } }
        enum Elsewhere { typealias SubSequence = Other }
        """
        #expect(try constructionRefuted("make", in: loop, elsewhere))
    }

    /// A lookup is kept per scope, not per site — so the key has to say where in that scope the
    /// site is. From a class's inheritance clause the class's own members are out of reach; from
    /// its body they are in. Here `Base` means the outer class in one and the nested struct in the
    /// other, and both are asked from the same declaration.
    @Test("a name in an inheritance clause and the same name in the body are different questions")
    func inheritanceClauseAndBodyAreDifferentLookups() throws {
        #expect(try constructionRefuted("make", in: """
        class Base { var n = 0 }
        class Sub: Base { struct Base { let id = UUID() }; let helper = Base() }
        func make() -> Sub { Sub() }
        """))
        #expect(try constructionRefuted("make", in: """
        class Base { let id = UUID() }
        class Sub: Base { struct Base { var n = 0 }; let helper = Base() }
        func make() -> Sub { Sub() }
        """))
    }
}
