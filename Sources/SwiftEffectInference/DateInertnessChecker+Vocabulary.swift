extension DateInertnessChecker {

    /// Identifiers that block wherever they are written as code, even where the package declares
    /// them.
    private static let blockingNames: Set<String> = [
        // Text
        "description", "debugDescription", "describing", "reflecting", "dump", "debugPrint",
        "customPlaygroundQuickLook", "customMirror",
        "Text", "LocalizedStringKey", "LocalizedStringResource", "NSLocalizedString",
        "AttributedString", "NSAttributedString",
        // Settings
        "Calendar", "NSCalendar", "TimeZone", "NSTimeZone", "Locale", "NSLocale",
        "DateComponents", "NSDateComponents", "dateTime", "ISO8601Format", "formatted",
        "dateFormat", "dateStyle", "timeStyle", "NSPredicate", "NSExpression", "NSComparisonPredicate",
        "Environment", "EnvironmentValues", "autoupdatingCurrent",
        // Clocks, randomness, identifiers, environment
        "localtime", "localtime_r", "gmtime", "gmtime_r", "mktime", "timegm", "timelocal",
        "strftime", "strftime_l", "strptime", "ctime", "ctime_r", "asctime", "asctime_r", "tzset",
        "tzname", "difftime", "CACurrentMediaTime", "clock_gettime_nsec_np", "ProcessInfo",
        "Timer", "RunLoop", "SystemRandomNumberGenerator", "srand", "srandom", "SecRandomCopyBytes",
        "getentropy", "arc4random_buf", "getenv", "setenv", "Bundle", "shuffle", "random",
        "randomElement", "shuffled", "defaultCStringEncoding", "hashValue", "hash", "Hasher", "_rawHashValue",
        // An address is a fresh identity: ASLR moves the stack, and each object has its own.
        "ObjectIdentifier", "Unmanaged", "unsafeBitCast", "bitPattern", "unsafeAddress", "unsafeMutableAddress",
        // Memory never written: `Array(unsafeUninitializedCapacity:)`, `InlineArray[unchecked:]`.
        "unchecked", "uninitialized", "InlineArray",
        // C's formatted I/O, whose numbers follow the process's `LC_NUMERIC`, and whose variadic
        // overloads take a call a package function of that name was written for.
        "printf", "snprintf", "sprintf", "fprintf", "dprintf", "asprintf", "vprintf", "vsnprintf",
        "vsprintf", "vfprintf", "vasprintf", "scanf", "sscanf", "fscanf", "vsscanf", "NSLog", "syslog",
        // Key-value coding runs a member named by a string (`timeIntervalSinceNow`); bridging hands a
        // value to it; a path's `~` is the user's home; a capacity is what the allocator gave.
        "dictionaryWithValues", "forKeys", "setValuesForKeys", "expandingTildeInPath",
        "abbreviatingWithTildeInPath", "resolvingSymlinksInPath", "standardizingPath", "capacity",
        // A buffer's address is a fresh identity; `%p` formats one.
        "baseAddress", "withCString", "withUTF8", "withContiguousStorageIfAvailable",
        "withContiguousMutableStorageIfAvailable", "withMemoryRebound", "withVaList", "withExtendedLifetime",
        "isTriviallyIdentical", "isIdentical", "span", "mutableSpan", "Span", "MutableSpan", "RawSpan",
        // Bytes handed to a closure, and offsets into them, are an address; so is a platform string.
        "withBytes", "byteOffsets", "withPlatformString",
    ]

    /// Free functions that read a clock or a random source when called, but whose names are too
    /// common to block as bare identifiers: `time` and `clock` name properties everywhere.
    static let blockingFreeCalls: Set<String> = ["time", "clock", "rand"]

    /// Name fragments that block wherever they occur: every unsafe pointer API, underscored or not
    /// (`_withUnprotectedUnsafePointer`).
    private static let blockingFragments = ["Unsafe", "unsafe", "Format", "unchecked", "Unchecked"]

    /// Name prefixes that block: every `localized…` member, Core Foundation's date, calendar, time
    /// zone and locale families, GameplayKit's random sources, and the UUID generators.
    private static let blockingPrefixes = [
        "localized", "CFDate", "CFCalendar", "CFTimeZone", "CFLocale", "CFAbsoluteTime", "CFGregorian",
        "CFUUIDCreate", "uuid_generate", "GKRandom", "GKARC4", "GKMersenne", "GKLinearCongruential",
        "withUnsafe", "unsafe", "_", "objc_", "random", "withPlatform",
    ]

    /// Name suffixes that block: every Foundation formatter and format style.
    private static let blockingSuffixes = ["Formatter", "FormatStyle"]

    /// Member names that conventionally read a clock: `scheduler.now`, `clock.now`,
    /// `provider.currentDate`. A property is judged at its declaration, so main already misses
    /// these when no `Date` is written; the gate keeps them from losing the token that refuted
    /// them where one is. A parameter named `now` is not a member access and stays relaxable.
    static let blockingMemberNames: Set<String> = [
        "now", "current", "currentDate", "currentTime", "currentTimestamp", "uptimeNanoseconds",
        "timeIntervalSinceReferenceDate",
    ]

    /// Key path components that read SwiftUI's environment settings.
    static let blockingKeyPathComponents: Set<String> = ["locale", "timeZone", "calendar"]

    /// Attributes that hand no code to anything: effects, isolation, availability, inlining.
    private static let inertAttributes: Set<String> = [
        "escaping", "Sendable", "MainActor", "autoclosure", "discardableResult", "available",
        "inlinable", "usableFromInline", "unknown", "preconcurrency", "nonobjc", "objc",
    ]

    /// Whether an attribute spelled `name` hands no code to anything, when the package declares no
    /// type of that name (a property wrapper or global actor spelled `MainActor`).
    static func isInertName(_ name: String) -> Bool {
        inertAttributes.contains(name)
    }

    /// The standard library's operators. Any other spells a function the body never names, and must
    /// be one the package declares and can vouch for (`0 <~ "Hi"` can convert the literal to an SDK
    /// type).
    static let standardOperators: Set<String> = [
        "+", "-", "*", "/", "%", "==", "!=", "<", ">", "<=", ">=", "&&", "||", "!", "~", "&", "|", "^",
        "<<", ">>", "&+", "&-", "&*", "&<<", "&>>", "??", "...", "..<", "~=", "===", "!==",
        "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", "&+=", "&-=", "&*=", "&<<=", "&>>=",
    ]

    /// `name`, when the blocklist refuses it.
    static func blocked(_ name: String) -> String? {
        // `Date` and `UUID` are markers too; where they only name the type is the scan's question.
        let isOtherMarker = PurityInferrer.isMarkerName(name) && !TypePositionRelaxation.relaxableMarkers.contains(name)
        let refused = blockingNames.contains(name) || isOtherMarker
            || blockingPrefixes.contains(where: name.hasPrefix)
            || blockingSuffixes.contains(where: name.hasSuffix)
            || blockingFragments.contains(where: name.contains)
        return refused ? name : nil
    }

    /// The protocols (and existentials) a cast may name only to recover a hidden value.
    static let castProtocols: Set<String> = [
        "Any", "AnyObject", "AnyHashable", "Error", "Sendable", "Sequence", "Collection",
        "BidirectionalCollection", "RandomAccessCollection", "MutableCollection", "RangeReplaceableCollection",
        "IteratorProtocol", "LazySequenceProtocol", "LazyCollectionProtocol", "Equatable", "Hashable",
        "Comparable", "Identifiable", "Codable", "Encodable", "Decodable", "StringProtocol", "Decoder",
        "Encoder", "CodingKey", "BinaryInteger", "FixedWidthInteger", "SignedInteger", "UnsignedInteger",
        "Numeric", "SignedNumeric", "AdditiveArithmetic", "FloatingPoint", "BinaryFloatingPoint",
        "CustomStringConvertible", "CustomDebugStringConvertible",
    ]
}
