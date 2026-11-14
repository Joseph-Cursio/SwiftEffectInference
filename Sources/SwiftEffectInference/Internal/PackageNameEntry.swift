/// One declaration `PackageNameCollector` saw.
struct PackageNameEntry: Sendable, Equatable {

    /// A parameter, as a call must match it.
    struct Parameter: Sendable, Equatable, Hashable {
        let label: String?
        let hasDefault: Bool
        let isVariadic: Bool
        /// An `inout` parameter takes only a `&x` argument, and only it does: `gethostname(&buffer,
        /// n)` cannot bind to a package `gethostname(_: [CChar], _: Int)`, nor `umask(0)` to a
        /// package `umask(_: inout UInt16)`. A call spells an `&` argument's label `&label`.
        var isInout = false

        /// The label a call spells for an argument this parameter binds.
        var spelled: String? { isInout ? "&" + (label ?? "") : label }

        /// Whether a call with `labels` (`nil` for an unlabelled argument or a trailing closure)
        /// binds to `parameters` with every argument written: an omitted default or a variadic
        /// would let an SDK overload of exactly that arity win instead (`getpid()` over a package
        /// `getpid(_: Int = 0)`).
        /// The label a trailing closure stands for: it binds to a parameter of any label.
        static let trailingClosure = "{}"

        static func match(_ parameters: [Self], labels: [String?]) -> Bool {
            parameters.count == labels.count && !parameters.contains(where: \.isVariadic)
                && zip(parameters, labels).allSatisfy { $0.spelled == $1 || $1 == trailingClosure }
        }

        /// Whether a call with `labels` could bind to `parameters` at all, omitting defaults and
        /// filling variadics: the question for something that must not be vouched for.
        static func mayMatch(_ parameters: [Self], labels: [String?]) -> Bool {
            var index = labels.startIndex
            for parameter in parameters {
                if index < labels.endIndex, labels[index] == parameter.spelled || labels[index] == trailingClosure {
                    index += 1
                    while parameter.isVariadic, index < labels.endIndex, labels[index] == nil { index += 1 }
                } else if !parameter.hasDefault, !parameter.isVariadic {
                    return false
                }
            }
            return index == labels.endIndex
        }
    }

    enum Shape: Sendable, Equatable, Hashable {
        case type
        case value
        case function([Parameter])
        /// An enum case, with its associated values' parameters, or `nil` for none.
        case enumCase([Parameter]?)
    }

    let name: String
    /// The qualified path of the type it is a member of, or `""` at the top level.
    let container: String
    let shape: Shape
    var isProtocol = false
    var isOperator = false
    /// Every name its initial value (or an associated value's default) spells.
    var initializerNames: Set<String> = []
    /// The qualified paths of the types lexically around it, outermost first.
    var scopes: [String] = []
    /// A class or an actor, whose `Identifiable` default `id` is its identity.
    var isClass = false
    var isAlias = false
    var aliasTarget: [String]?
    var isGeneric = false
    var isInsideProtocol = false
    var isInert = true
    /// Every type name its declared types spell, with `"->"` for a returned or stored function type
    /// and `".Type"` for a metatype, neither of which is ever in the vocabulary.
    var mentions: Set<String> = []
    /// The names of the attributes written on it.
    var attributes: [String] = []

    var isType: Bool { shape == .type }
    var path: String { container.isEmpty ? name : container + "." + name }
}
