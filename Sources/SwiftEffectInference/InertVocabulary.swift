import SwiftSyntax

/// The names a body may reach and still let a `Date` or `UUID` named as a type go unrefuted (#30).
///
/// The relaxation is an allowlist, because a list of what to refuse could never be finished. Three
/// rounds of adversarial review against blocklists found 60, 23 and 22 ways through, and a fourth
/// found nearly 300 more: `sysctlbyname`, `mach_approximate_time`, `localeconv`, `mktemp`,
/// `gethostid`, `OSSignpostID`, `localizedStandardCompare`, a key path hidden in a `value(forKey:)`
/// string. The SDK is open, and the token was what refuted all of them in a body that spelled the
/// type. So every identifier the body writes must resolve to one of:
/// - **a local**, per `LocalNameScope`;
/// - **this vocabulary:** the standard library's values, collections and arithmetic, and `Date`'s
///   and `UUID`'s inert members (`timeIntervalSince1970`, `addingTimeInterval`, `uuidString`);
/// - **a name the package declares** where Swift would reach it (`PackageNames`, from
///   `ConstructionFacts`): a callee in the package is judged at its own declaration, as every callee
///   is.
///
/// Anything else may be the SDK reading a clock, a random source or a setting, so the body keeps
/// the old verdict. An inferrer built without `ConstructionFacts` knows no package names, and
/// relaxes only a body written in locals and this vocabulary.
///
/// A member the package declares can share its spelling with an SDK member (`perform`, `value`),
/// and one written on a value of an SDK type is then let through: the receiver's type is not known
/// here. `DateInertnessChecker`'s blocklist still refuses the names known to read ambient state
/// wherever they are declared. Names are compared without backticks.
enum InertVocabulary {

    /// Standard library types and functions, usable as values: `Int.max`, `Array(xs)`, `zip(a, b)`.
    static let freeNames: Set<String> = [
        "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        "Double", "Float", "Float32", "Float64", "Bool", "String", "Substring", "Character",
        "Array", "ContiguousArray", "ArraySlice", "Dictionary", "Set", "Optional", "Result",
        "Range", "ClosedRange", "Never", "TimeInterval",
        "min", "max", "abs", "zip", "stride", "repeatElement", "sequence", "swap", "numericCast",
        "precondition", "preconditionFailure", "assert", "assertionFailure", "fatalError",
    ]

    /// Type names that may be written in a type position. `Date` and `UUID` are among them, as the
    /// relaxation's subject; written as a value they are still markers.
    static let typeNames: Set<String> = freeNames.union([
        // Not `Element`, `Key`, `Value` or `Index`: a `where` clause can bind them to an SDK type.
        // Not `AnyObject`: a member written on one is sent as an Objective-C selector, which a package
        // `@objc(timeIntervalSinceNow)` member can spell like any SDK method.
        "Date", "UUID", "Foundation", "Swift", "Void", "Any", "AnyHashable", "Error",
        "Sequence", "Collection", "BidirectionalCollection", "RandomAccessCollection",
        "MutableCollection", "RangeReplaceableCollection", "IteratorProtocol",
        "Equatable", "Hashable", "Comparable", "Identifiable", "Sendable",
        "Codable", "Encodable", "Decodable", "StringProtocol", "Decoder", "Encoder", "CodingKey",
        "BinaryInteger", "FixedWidthInteger", "SignedInteger", "UnsignedInteger", "Numeric",
        "SignedNumeric", "AdditiveArithmetic", "FloatingPoint", "BinaryFloatingPoint",
        // Not the key path types: one returned from the package can be applied to a `Date` here,
        // `\.timeIntervalSinceNow`.
    ])

    /// Types an initializer with no arguments builds a constant of: `String()`, `[Int]()`.
    static let constantInitializedTypes: Set<String> = [
        "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        "Double", "Float", "Float32", "Float64", "Bool", "String", "Substring",
        "Array", "ContiguousArray", "Dictionary", "Set",
    ]

    /// Members that may be written after a dot, called or not.
    static let members: Set<String> = [
        // Collections
        "count", "isEmpty", "first", "last", "map", "compactMap", "flatMap", "filter", "reduce",
        "sorted", "sort", "reversed", "reverse", "contains", "allSatisfy", "firstIndex", "lastIndex",
        "indices", "enumerated", "prefix", "suffix", "dropFirst", "dropLast", "joined", "split",
        "append", "insert", "remove", "removeAll", "removeFirst", "removeLast", "removeSubrange",
        "removeValue", "updateValue", "popLast", "popFirst", "keys", "values", "offset", "element",
        "min", "max", "starts", "isSubset", "isSuperset", "isDisjoint", "union", "intersection",
        "subtracting", "symmetricDifference", "formUnion", "formIntersection", "subtract", "merge",
        "merging", "mapValues", "compactMapValues", "forEach", "lazy", "startIndex", "endIndex",
        "index", "distance", "advanced", "swapAt", "elementsEqual", "replaceSubrange", "partition",
        "underestimatedCount", "reserveCapacity",
        // Optional and Result
        "some", "none", "success", "failure", "get",
        // Text, locale-free
        "lowercased", "uppercased", "hasPrefix", "hasSuffix", "utf8", "utf16", "unicodeScalars",
        "isLetter", "isNumber", "isWhitespace", "isUppercase", "isLowercase", "wholeNumberValue",
        "asciiValue", "components",
        // Numbers
        "isNaN", "isFinite", "isInfinite", "isZero", "magnitude", "rounded", "round", "squareRoot",
        "truncatingRemainder", "remainder", "quotientAndRemainder", "isMultiple", "signum",
        "negate", "pi", "zero", "greatestFiniteMagnitude", "leastNonzeroMagnitude", "infinity",
        "nan", "bitWidth", "rawValue",
        // Date and UUID, by their value
        "timeIntervalSince1970", "timeIntervalSince", "addingTimeInterval", "addTimeInterval",
        "distantPast", "distantFuture", "uuidString", "uuid",
    ]

    /// Members that are inert read as a property and not called: a dictionary element's `value`,
    /// never `value(forKey:)`.
    static let propertyMembers: Set<String> = ["key", "value"]

    /// Argument labels that pick an overload reading a setting or a description, on any callee:
    /// `String(format:)`, `String(describing:)`, `value(forKey:)`, `String(contentsOf:)`.
    static let blockingLabels: Set<String> = [
        "format", "locale", "localized", "forKey", "forKeyPath", "describing", "reflecting",
        "calendar", "timeZone", "contentsOf", "contentsOfFile", "contentsOfURL",
        // Read through a pointer for as long as a count says, past what it points at.
        "utf16CodeUnits", "utf16CodeUnitsNoCopy", "bytesNoCopy", "cString", "validatingCString",
    ]

    /// The members a base-less `.name`, or a static on a spelled type (`Int.max`), may be. A base-less
    /// member's type comes from a context the body need not spell, a return type or a callee's
    /// parameter, so most members are not safe there: `.components(…)` and `.offset(…)` are format
    /// styles that read the user's locale.
    static let baseLessMembers: Set<String> = [
        "some", "none", "success", "failure", "zero", "infinity", "nan", "pi", "max", "min",
        "greatestFiniteMagnitude", "leastNonzeroMagnitude", "distantPast", "distantFuture",
    ]

    /// Why `token` keeps the body from relaxing, or `nil` when it resolves to a local, this
    /// vocabulary, or one of the package's names.
    static func unresolved(_ token: TokenSyntax, package: PackageNames, root: Syntax? = nil) -> String? {
        let name = token.bareName
        guard let parent = token.parent else { return nil }
        // Swift compares names by their scalars, but `String` compares them canonically: a Kelvin
        // sign (U+212A) is `==` to an ASCII `K` here and a different name to the compiler.
        if !token.text.unicodeScalars.allSatisfy(\.isASCII) { return "`\(name)`, which is not ASCII" }
        if isOutsideCode(token) || isDeclarationOrLabel(token, parent: parent) { return nil }
        let resolves: Bool
        if let reference = parent.as(DeclReferenceExprSyntax.self), reference.baseName.id == token.id {
            resolves = resolvesReference(reference, name: name, at: token, package: package, root: root)
        } else if parent.is(ClosureCaptureSyntax.self) || parent.is(IdentifierPatternSyntax.self) {
            // `[clock]` with no initializer, and `if let clock`, read `clock` from outside.
            resolves = resolvesFree(name, called: nil, at: token, package: package, root: root)
        } else if let type = parent.as(IdentifierTypeSyntax.self), type.name.id == token.id {
            // A local type around the body, or an outer function's, is what Swift picks.
            let shadowed = LocalNameScope.declares(name, visibleAt: token)
            resolves = !shadowed && (vocabulary(typeNames, has: name, package) || package.resolvesType(name, at: token))
                || LocalNameScope.declares(name, visibleAt: token, asType: true, root: root)
        } else if let type = parent.as(MemberTypeSyntax.self), type.name.id == token.id {
            resolves = resolvesMemberType(type, at: token, package: package)
        } else {
            return "`\(name)` where no name is resolved"
        }
        if resolves { return nil }
        return package.refused.contains(name)
            ? "`\(name)`, which the package declares where it cannot be judged" : "`\(name)`"
    }

    /// Whether `name` is a vocabulary static read as written: a constant read, not called (`Int.max`,
    /// never `Int.max(0)`, which only a package static could be), or an `Optional` or `Result` case
    /// built from one value.
    private static func isStatic(_ name: String, called labels: [String?]?, _ package: PackageNames) -> Bool {
        guard vocabulary(baseLessMembers, has: name, package) else { return false }
        if ["some", "success", "failure"].contains(name) { return labels == nil || labels == [nil] }
        return labels == nil
    }

    /// Whether the vocabulary may vouch for `name`: not when the package redeclares it somewhere it
    /// cannot be judged (`struct Box { typealias first = Date }`), since the receiver may be that.
    private static func vocabulary(_ set: Set<String>, has name: String, _ package: PackageNames) -> Bool {
        set.contains(name) && !package.refused.contains(name)
    }

    /// `Foundation.Date` and `Swift.Result` by the vocabulary, a package type by its path.
    private static func resolvesMemberType(
        _ type: MemberTypeSyntax, at token: TokenSyntax, package: PackageNames
    ) -> Bool {
        guard let path = TypeShapeCollector.components(of: TypeSyntax(type)) else { return false }
        if ["Foundation", "Swift"].contains(path.first), path.count == 2, vocabulary(typeNames, has: path[1], package) {
            return true
        }
        return (PackageNames.enclosingTypePaths(of: token) + [""]).contains { prefix in
            package.resolvesTypePath(prefix.isEmpty ? path : prefix.split(separator: ".").map(String.init) + path)
        }
    }

    private static func resolvesReference(
        _ reference: DeclReferenceExprSyntax, name: String, at token: TokenSyntax, package: PackageNames, root: Syntax?
    ) -> Bool {
        let parent = reference.parent
        let member = parent?.as(MemberAccessExprSyntax.self).flatMap { $0.declName.id == reference.id ? $0 : nil }
        // `RuleBaseline(…)` runs whatever initializer default it leaves out, `UUID()` among them.
        if package.unconstructibleNames.contains(name),
           callLabels(of: member.map(Syntax.init) ?? Syntax(reference), naming: reference) != nil {
            return false
        }
        if let member {
            let labels = callLabels(of: Syntax(member), naming: reference)
            if package.mayBeExcludedMember(name, called: labels) { return false }
            // A base-less `.name` is a static of a contextual type the body need not spell, which can be
            // an SDK type with a static of that name (`.preferredLocales` for a `Locale?`): only the
            // vocabulary's constants vouch, never a package member spelled the same.
            guard let base = member.base else { return isStatic(name, called: labels, package) }
            if let receiver = knownReceiver(base, at: token, package: package) {
                // `self.x`, `String.Comparator`, `Tag.RawValue`: the receiver is known, so a member
                // another package type declares is not this one; on an SDK type, a package member
                // spelled like one of its own may lose to it; and a package type's members are only
                // what it declares (its inferred `RawValue` is the raw type).
                let vouched = receiver.isPackage ? false
                    : receiver.isMetatype ? isStatic(name, called: labels, package)
                    : vocabulary(members, has: name, package)
                return vouched || package.cleanContainers.contains(receiver.path)
                    && package.resolvesMember(name, in: receiver.path, called: labels)
            }
            return vocabulary(members, has: name, package) || package.resolvesMember(name, called: labels)
                || (labels == nil && vocabulary(propertyMembers, has: name, package))
        }
        if parent?.is(KeyPathPropertyComponentSyntax.self) == true {
            return vocabulary(members.union(propertyMembers), has: name, package)
                || package.resolvesMember(name, called: nil)
        }
        if namesCollectionType(reference) {
            return vocabulary(typeNames, has: name, package) || package.resolvesType(name, at: token)
        }
        let labels = callLabels(of: Syntax(reference), naming: reference)
        return resolvesFree(name, called: labels, at: token, package: package, root: root)
    }

    /// A member's receiver whose type the source spells: the type's path, whether the receiver is
    /// the type itself rather than a value of it, and whether the package declares the type.
    private struct KnownReceiver {
        let path: String
        let isMetatype: Bool
        let isPackage: Bool
    }

    /// The type a member's receiver is, when the source spells it: `self` (the enclosing type, a
    /// metatype in a static member) or a standard-library type named as a value (`String.x`).
    private static func knownReceiver(
        _ base: ExprSyntax, at token: TokenSyntax, package: PackageNames
    ) -> KnownReceiver? {
        // `(String).Comparator` is `String.Comparator`.
        if let tuple = base.as(TupleExprSyntax.self), tuple.elements.count == 1,
           let only = tuple.elements.first, only.label == nil {
            return knownReceiver(only.expression, at: token, package: package)
        }
        // `Catalog.Tag`, a package type's nested type.
        if let member = base.as(MemberAccessExprSyntax.self), let inner = member.base,
           let outer = knownReceiver(inner, at: token, package: package), outer.isPackage, outer.isMetatype {
            let path = outer.path + "." + member.declName.baseName.bareName
            return package.resolvesTypePath(path.split(separator: ".").map(String.init))
                ? KnownReceiver(path: path, isMetatype: true, isPackage: true) : nil
        }
        guard let reference = base.as(DeclReferenceExprSyntax.self) else { return nil }
        if reference.baseName.tokenKind == .keyword(.self) {
            guard let path = PackageNames.enclosingTypePaths(of: token).first else { return nil }
            return KnownReceiver(path: path, isMetatype: isInStaticMember(token), isPackage: false)
        }
        let name = reference.baseName.bareName
        guard name.first?.isUppercase == true,
              !LocalNameScope.declares(name, visibleAt: reference.baseName) else { return nil }
        if let path = package.typePath(of: name, at: reference.baseName) {
            return KnownReceiver(path: path, isMetatype: true, isPackage: true)
        }
        return freeNames.contains(name) ? KnownReceiver(path: name, isMetatype: true, isPackage: false) : nil
    }

    private static func isInStaticMember(_ token: TokenSyntax) -> Bool {
        var current = token.parent
        while let node = current {
            if let function = node.as(FunctionDeclSyntax.self) {
                return function.modifiers.contains { [.keyword(.static), .keyword(.class)].contains($0.name.tokenKind) }
            }
            if let variable = node.as(VariableDeclSyntax.self),
               variable.parent?.parent?.is(MemberBlockItemListSyntax.self) == true {
                return variable.modifiers.contains { [.keyword(.static), .keyword(.class)].contains($0.name.tokenKind) }
            }
            current = node.parent
        }
        return false
    }

    /// A local first, then (unless an enclosing type leaves out a member of that name, which Swift
    /// would find first) the vocabulary and the package.
    private static func resolvesFree(
        _ name: String, called labels: [String?]?, at token: TokenSyntax, package: PackageNames, root: Syntax?
    ) -> Bool {
        // A name written with its labels, `setlocale(_:_:)`, is a function, never a local value.
        let isCompound = token.parent?.as(DeclReferenceExprSyntax.self)?.argumentNames != nil
        if !isCompound, LocalNameScope.declares(name, visibleAt: token, root: root) { return true }
        if LocalNameScope.isOuterLocal(name, visibleAt: token, root: root) || package.shadowsFree(name, at: token) {
            return false
        }
        return vocabulary(freeNames, has: name, package) || package.resolvesFree(name, called: labels, at: token)
    }

    /// The argument labels `callee` is called with (`nil` for an unlabelled argument,
    /// `Parameter.trailingClosure` for a trailing closure), the labels a function value is named
    /// with (`f(_:at:)`), or `nil` when neither.
    private static func callLabels(of callee: Syntax, naming reference: DeclReferenceExprSyntax) -> [String?]? {
        if let names = reference.argumentNames {
            return names.arguments.map { $0.name.tokenKind == .wildcard ? nil : $0.name.bareName }
        }
        var node = callee
        while let parent = node.parent,
              parent.is(OptionalChainingExprSyntax.self) || parent.is(ForceUnwrapExprSyntax.self) {
            node = parent
        }
        guard let call = node.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == node.id else {
            return nil
        }
        // A trailing closure binds to a parameter whatever its label.
        let closures = (call.trailingClosure == nil ? 0 : 1) + call.additionalTrailingClosures.count
        let labels = call.arguments.map { argument in
            argument.expression.is(InOutExprSyntax.self)
                ? "&" + (argument.label?.bareName ?? "") : argument.label?.bareName
        }
        return labels + Array(repeating: PackageNameEntry.Parameter.trailingClosure, count: closures)
    }

    /// Whether `reference` is an element type of a collection literal written as a type and called:
    /// the `Date` and `Int` of `[Date: Int]()`.
    private static func namesCollectionType(_ reference: DeclReferenceExprSyntax) -> Bool {
        let literal: Syntax?
        if let element = reference.parent?.as(ArrayElementSyntax.self) {
            literal = element.parent?.parent
        } else if reference.parent?.is(DictionaryElementSyntax.self) == true {
            literal = reference.parent?.parent?.parent
        } else {
            literal = nil
        }
        guard let literal, let call = literal.parent?.as(FunctionCallExprSyntax.self) else { return false }
        return call.calledExpression.id == literal.id
    }

    /// Whether `token` is in a `#if` condition or an availability check, which run nothing.
    private static func isOutsideCode(_ token: TokenSyntax) -> Bool {
        var child = Syntax(token)
        var current = token.parent
        while let node = current {
            if let clause = node.as(IfConfigClauseSyntax.self), clause.condition?.id == child.id { return true }
            if node.is(AvailabilityConditionSyntax.self) || node.is(PlatformVersionSyntax.self) { return true }
            child = node
            current = node.parent
        }
        return false
    }

    /// Whether `token` declares a name or labels an argument, rather than referring to anything. A
    /// capture declares its name only when it has an initializer: `[x = y]`, not `[x]`.
    private static func isDeclarationOrLabel(_: TokenSyntax, parent: Syntax) -> Bool {
        switch parent.kind {
        case .functionParameter, .closureShorthandParameter, .closureParameter,
             .functionDecl, .genericParameter, .enumCaseElement, .labeledExpr,
             .declNameArgument, .tupleTypeElement, .tuplePatternElement, .multipleTrailingClosureElement,
             .accessorParameters, .labeledStmt, .continueStmt, .breakStmt, .declModifierDetail,
             .closureCaptureSpecifier, .enumCaseParameter, .labeledSpecializeArgument:
            return true

        case .closureCapture:
            return parent.as(ClosureCaptureSyntax.self)?.initializer != nil

        case .identifierPattern:
            // `if let x` with no initializer reads the `x` outside as well as binding one.
            guard let binding = parent.parent?.as(OptionalBindingConditionSyntax.self) else { return true }
            return binding.initializer != nil

        default:
            return false
        }
    }
}
