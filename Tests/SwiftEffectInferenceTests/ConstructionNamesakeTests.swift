import SwiftParser
@testable import SwiftEffectInference
import Testing

/// What `ConstructionFacts` says where one name is declared in many files — the shape of the swift
/// compiler's tests, where every file is its own program and `class A` is declared 1,700 times.
///
/// Each name means every one of its namesakes (any doubt refutes), so these pin which types refute
/// and the witness reported first among the namesakes: whatever makes such a package cheaper to
/// build must leave both alone.
@Suite("ConstructionFacts — namesakes")
struct ConstructionNamesakeTests {

    /// `copies` files declaring `class A {}` and `class B: A`, whose body builds an `A` — so `B`'s
    /// superclass, and what its default builds, are every `A`. Halfway, an `A` reads the clock; at
    /// the end, one mints an identity.
    static func subclassNamesakes(copies: Int) -> [String] {
        let plain = Array(repeating: "class A {}\nclass B: A { let a = A() }", count: copies / 2)
        return plain + ["class A { let at = Date() }"] + plain + ["class A { let id = UUID() }"]
    }

    /// `copies` files declaring `struct S`, whose default builds `Self.Inner` — every `S`'s nested
    /// `Inner`, read through each of `S`'s namesakes. Halfway, an `Inner` reads the clock; at the
    /// end, one mints an identity.
    static func selfNamesakes(copies: Int) -> [String] {
        let plain = Array(repeating: "struct S { struct Inner {}; var inner = Self.Inner() }", count: copies / 2)
        return plain + ["struct S { struct Inner { let at = Date() }; var inner = Self.Inner() }"]
            + plain + ["struct S { struct Inner { let id = UUID() }; var inner = Self.Inner() }"]
    }

    /// `count` classes, each building `Self.Other` — its own nested class, and its subclasses'
    /// namesakes of it. Only `Leaf0.Other` mints an identity.
    ///
    /// With `distinct`, each nested class has a name of its own, so that nothing but `Self` reads
    /// all of the classes.
    static func selfInClasses(count: Int, distinct: Bool = false) -> [String] {
        (0..<count).map { index in
            let name = distinct ? "Other\(index)" : "Other"
            let other = index == 0 ? "class \(name) { let id = UUID() }" : "class \(name) {}"
            return "class Leaf\(index) { \(other); let other = Self.\(name)() }"
        }
    }

    @Test("a subclass's namesake superclasses each refute it, and the first collected is the witness")
    func subclassNamesakesRefute() throws {
        var sources = Self.subclassNamesakes(copies: 40)
        sources.append("func make() -> B { B() }")
        let facts = ConstructionFacts.build(from: sources.map { Parser.parse(source: $0) })

        #expect(facts.refutedTypeNames == ["A", "B"])
        #expect(ConstructionCostTests.path(facts.refutation(constructing: "B")) == [
            "B.a", "A.at", "references the nondeterminism marker `Date`"
        ])
        #expect(ConstructionCostTests.path(try constructionRefutation(of: "make", in: sources)) == [
            "B.a", "A.at", "references the nondeterminism marker `Date`"
        ])
    }

    @Test("`Self` means every namesake, each one's nested type is a candidate, and the first collected is the witness")
    func selfNamesakesRefute() throws {
        var sources = Self.selfNamesakes(copies: 40)
        sources.append("func make() -> S { S() }")
        let facts = ConstructionFacts.build(from: sources.map { Parser.parse(source: $0) })

        #expect(facts.refutedTypeNames == ["S", "S.Inner"])
        #expect(ConstructionCostTests.path(try constructionRefutation(of: "make", in: sources)) == [
            "S.inner", "S.Inner.at", "references the nondeterminism marker `Date`"
        ])
    }

    @Test("`Self` in a class reaches only its own nested type when nothing subclasses it")
    func selfInClassesRefute() throws {
        var sources = Self.selfInClasses(count: 40)
        sources.append("func make() -> Leaf0 { Leaf0() }\nfunc other() -> Leaf1 { Leaf1() }")
        let facts = ConstructionFacts.build(from: sources.map { Parser.parse(source: $0) })

        #expect(facts.refutedTypeNames == ["Leaf0", "Leaf0.Other"])
        #expect(ConstructionCostTests.path(try constructionRefutation(of: "make", in: sources)) == [
            "Leaf0.other", "Leaf0.Other.id", "references the nondeterminism marker `UUID`"
        ])
        #expect(try constructionRefutation(of: "other", in: sources) == nil)
    }
}
