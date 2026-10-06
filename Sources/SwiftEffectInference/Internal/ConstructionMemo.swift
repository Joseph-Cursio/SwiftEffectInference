import SwiftSyntax

/// What `ConstructionFacts` has already worked out, so that no question is answered twice — never
/// part of what the table says.
///
/// ## Why it exists
///
/// Every answer here is a function of the facts it was asked of, and the same questions came back
/// constantly. Each decode site re-walked the member-type graph, resolving every stored property's
/// type afresh at every step, on every pass. A protocol extension's initializer was walked once per
/// conformer, and its `self.init` resolved to every conformer each time. Whether a class could
/// take a contextless `.init(label:)` — or what `T.init` runs as a function value — was found by
/// trying every path up its superclasses: with a namesake at every level, 2⁸ per class. Building
/// over swift-nio, swift-argument-parser, swift-algorithms and swift-syntax side by side took
/// 2.1 s against 0.4 s for the four one by one; adding swift-collections, it never finished (see
/// `declarations(named:from:)` on the loop through `Self`).
///
/// ## What it may keep, and for how long
///
/// - **For the whole build: what names mean.** A lookup reads only the declarations' names, kinds,
///   inheritance and sites, and the collected aliases and stored-property types — none of which a
///   pass changes. So lookups (`declarations(named:from:)`) and the edges of the decode graph are
///   kept across passes.
/// - **For one pass: what is refuted.** Each pass judges against fixed declarations and fills
///   slots for the next, so what a body constructs, what a decode runs, whether a class can take a
///   call shape and what a reference to an initializer runs are kept only until the pass ends
///   (`startPass()`).
///
/// A lookup is keyed by where its answer can differ, not by the node it was asked from: the
/// innermost enclosing node the resolution reads (`LookupKey`), so every call in one body shares
/// one answer.
///
/// ## Threads
///
/// A memo is never shared between threads. `build(from:)` attaches one for its own passes and
/// detaches it before returning — handing on only what names mean, as an immutable `Settled` —
/// and a walk over a body outside a build makes its own (`ConstructionFacts.memoised()`), which
/// is the only place that walk's answers are kept.
final class ConstructionMemo: @unchecked Sendable {

    /// Held by `ConstructionFacts`, and invisible to its equality: two tables that say the same
    /// thing are equal whatever either has cached.
    struct Slot: Sendable, Equatable {
        var instance: ConstructionMemo?
        /// What the build resolved, handed on with the table it returns.
        var settled = Settled()
        static func == (lhs: Slot, rhs: Slot) -> Bool { true }
    }

    /// The build's answers about names, kept on the table it returns: a name means after the build
    /// what it meant during it, so whoever judges with the table reads them instead of resolving
    /// afresh. Immutable — read from any thread without a lock.
    struct Settled: Sendable {
        var lookups: [LookupKey: [Int]] = [:]
        var decodeEdges: [Int: [DecodeEdge]] = [:]
    }

    /// What this memo resolved, to hand on.
    var settled: Settled { Settled(lookups: lookups, decodeEdges: decodeEdges) }

    // MARK: - For the whole build

    private(set) var lookups: [LookupKey: [Int]] = [:]
    /// The lookups being resolved.
    private var resolving: Set<LookupKey> = []
    var decodeEdges: [Int: [DecodeEdge]] = [:]

    // MARK: - For one pass

    /// What constructing anything in a body, a default or an attribute's arguments incurs.
    var walks: [Syntax: PurityRefutation?] = [:]
    /// The decode answer for each declaration, searched from it alone.
    var decodes: [Int: PurityRefutation?] = [:]
    /// Declarations whose decoding reaches no refutation at all, by any path.
    var undecodable: Set<Int> = []
    var fits: [FitKey: Bool] = [:]
    var references: [ReferenceKey: PurityRefutation?] = [:]

    // MARK: - Counted

    /// How many lookups have been resolved rather than read back, and how many declarations the
    /// decode search has stepped into, never reset — counted so that a test can see a question
    /// answered once rather than infer it from a clock.
    private(set) var lookupsResolved = 0
    var decodeSteps = 0

    /// Forgets what was refuted: the next pass judges against fuller facts.
    func startPass() {
        walks = [:]
        decodes = [:]
        undecodable = []
        fits = [:]
        references = [:]
    }

    /// Marks `key` as being resolved; `false` when it already is — the resolution has come back
    /// to a lookup it is inside of, with the same arguments, and would never end.
    func beginLookup(_ key: LookupKey) -> Bool {
        guard resolving.insert(key).inserted else { return false }
        lookupsResolved += 1
        return true
    }

    /// Ends `key`'s resolution with `found`.
    ///
    /// Kept even when a lookup inside it was cut short by coming back to one outside it. That
    /// answer is only where the loop was entered from, but no lookup that ends without the cut
    /// can ever read it: reading it means asking a lookup that, asked afresh, loops forever.
    func endLookup(_ key: LookupKey, found: [Int]) {
        resolving.remove(key)
        lookups[key] = found
    }
}

/// A lookup's arguments, with the site replaced by what of it the resolution reads.
///
/// A resolution reads the site's enclosing types and function-like bodies (the chain, the bodies
/// crossed), and — for shadowing — the generic parameters of the site and its ancestors and every
/// statement list around it. Nothing else. So two sites below the same innermost such node
/// resolve every spelling alike, and that node, with whether the site *is* it (the chain starts
/// above the site, shadowing at it), is the key.
struct LookupKey: Hashable, Sendable {
    let components: [String]
    let scope: Syntax?
    let siteIsScope: Bool
    let depth: Int
    let aliasesSeen: Set<String>

    init(components: [String], site: Syntax?, depth: Int, aliasesSeen: Set<String>) {
        self.components = components
        self.depth = depth
        self.aliasesSeen = aliasesSeen
        var current = site
        while let node = current, !Self.isRead(node) { current = node.parent }
        scope = current
        siteIsScope = current != nil && current == site
    }

    /// Whether a resolution reads `node` when it encloses a site: a type declaration or extension,
    /// a function-like body, or a statement list.
    private static func isRead(_ node: Syntax) -> Bool {
        switch node.kind {
        case .structDecl, .classDecl, .actorDecl, .enumDecl, .protocolDecl, .extensionDecl,
             .functionDecl, .initializerDecl, .deinitializerDecl, .accessorBlock, .subscriptDecl,
             .closureExpr, .codeBlockItemList:
            return true
        default:
            return false
        }
    }
}

/// One way decoding a declaration reaches another: through its superclass, or a stored property.
struct DecodeEdge: Sendable {
    let step: PurityRefutation.ConstructionStep
    let held: Int
}

/// Whether the declaration at `index` can take `call`, asked `depth` superclasses up.
struct FitKey: Hashable {
    let call: CallShape
    let index: Int
    let depth: Int
}

/// What `T.init(labels…)` as a function value runs, asked of the declaration at `index`, `depth`
/// superclasses up.
struct ReferenceKey: Hashable {
    let index: Int
    let labels: [String]?
    let depth: Int
}
