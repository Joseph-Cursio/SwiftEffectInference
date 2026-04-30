import Foundation

/// Stdlib-collection operations that are **not** anchors for bare-name
/// inference. The first-slice bare-name whitelist classifies `append`,
/// `insert`, and friends as non_idempotent, which is correct for
/// user-defined persistent-queue or database-row operations but wrong for
/// local `Array.append`, `Set.insert` (set-idempotent), and similar stdlib
/// mutations.
///
/// Each pair `(typeName, methodName)` identifies a specific stdlib method
/// call the resolver has classified by receiver type. Matches suppress the
/// bare-name inference result — the inferrer returns `nil` as though no
/// heuristic applied, which is the round-5 baseline behaviour for
/// user-defined receivers that happen not to match the whitelist.
///
/// ## What's excluded and why
///
/// - `Array.append`, `Array.insert`, `Array.remove*`: local array mutations.
///   Idempotent-irrelevant; business-state unaffected.
/// - `String.append`, `String.insert`: parallel to Array on the character
///   sequence.
/// - `Set.insert`, `Set.remove`, `Set.removeAll`: set semantics make these
///   idempotent by definition — inserting an already-present element is a
///   no-op.
/// - `Dictionary.removeValue`, `Dictionary.updateValue`: dictionary mutations
///   are key-addressed and therefore replay-safe by definition.
///
/// ## What's deliberately NOT excluded
///
/// - `Array.replaceSubrange`, `Array.swapAt`, `Array.sort`, etc.: less
///   common, and none are triggered by the current bare-name whitelist
///   anyway. Adding them preemptively would be scope creep.
/// - Any user-defined type methods that happen to share names with stdlib
///   methods: that's the problem receiver-type inference exists to fix —
///   user-defined receivers stay on the bare-name path.
public enum StdlibIdempotentMutations {

    /// Returns `true` when the `(receiver, method)` pair is a stdlib
    /// exclusion — i.e., a bare-name inference match that should be
    /// suppressed.
    ///
    /// Pair matches require the receiver to be `.stdlibCollection(name)`.
    /// Named or unresolved receivers are never excluded.
    public static func isExcluded(
        receiver: ResolvedReceiverType,
        method: String
    ) -> Bool {
        guard case let .stdlibCollection(typeName) = receiver else {
            return false
        }
        return excluded.contains(TypeMethodPair(type: typeName, method: method))
    }

    fileprivate struct TypeMethodPair: Hashable {
        let type: String
        let method: String
    }

    fileprivate static let excluded: Set<TypeMethodPair> = [
        // Array — local-mutation methods.
        TypeMethodPair(type: "Array", method: "append"),
        TypeMethodPair(type: "Array", method: "insert"),
        TypeMethodPair(type: "Array", method: "remove"),
        TypeMethodPair(type: "Array", method: "removeAll"),
        TypeMethodPair(type: "Array", method: "removeFirst"),
        TypeMethodPair(type: "Array", method: "removeLast"),

        // String — Character-sequence mutation, parallel to Array.
        TypeMethodPair(type: "String", method: "append"),
        TypeMethodPair(type: "String", method: "insert"),

        // Set — semantic idempotency (insert/remove/update are set-idempotent;
        // calling twice with the same element leaves the set in the same state).
        TypeMethodPair(type: "Set", method: "insert"),
        TypeMethodPair(type: "Set", method: "remove"),
        TypeMethodPair(type: "Set", method: "removeAll"),
        TypeMethodPair(type: "Set", method: "update"),

        // Dictionary — key-addressed mutation is replay-safe.
        TypeMethodPair(type: "Dictionary", method: "removeValue"),
        TypeMethodPair(type: "Dictionary", method: "updateValue")
    ]
}
