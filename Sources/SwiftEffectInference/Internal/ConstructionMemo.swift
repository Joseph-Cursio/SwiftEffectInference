import SwiftSyntax

/// What `ConstructionFacts` has already worked out, so that no question is answered twice — never
/// part of what the table says.
///
/// ## Why it exists
///
/// Every construction, decode and superclass names a type, and each resolved its name from
/// scratch — through every alias its head may mean, and every namesake — however often the same
/// spelling had been resolved from the same scope, on every pass.
///
/// ## What it may keep, and for how long
///
/// **For the whole build: what names mean.** A lookup reads only the declarations' names, kinds,
/// inheritance and sites, and the collected aliases and stored-property types — none of which a
/// pass changes — so its answer is kept across passes.
///
/// A lookup is keyed by where its answer can differ, not by the node it was asked from: the
/// innermost enclosing node the resolution reads (`LookupKey`), so every call in one body shares
/// one answer.
///
/// ## Threads
///
/// A memo is never shared between threads. `build(from:)` attaches one for its own passes and
/// detaches it before returning, and a walk over a body outside a build makes its own
/// (`ConstructionFacts.memoised()`), which is the only place that walk's answers are kept.
final class ConstructionMemo: @unchecked Sendable {

    /// Held by `ConstructionFacts`, and invisible to its equality: two tables that say the same
    /// thing are equal whatever either has cached.
    struct Slot: Sendable, Equatable {
        var instance: ConstructionMemo?
        static func == (lhs: Slot, rhs: Slot) -> Bool { true }
    }

    // MARK: - For the whole build

    private(set) var lookups: [LookupKey: [Int]] = [:]
    /// The lookups being resolved.
    private var resolving: Set<LookupKey> = []

    /// Marks `key` as being resolved; `false` when it already is — the resolution has come back
    /// to a lookup it is inside of, with the same arguments, and would never end.
    func beginLookup(_ key: LookupKey) -> Bool {
        resolving.insert(key).inserted
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
struct LookupKey: Hashable {
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
