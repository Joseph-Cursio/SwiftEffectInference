// MARK: - Receiver shapes and name lexicon

extension CallSiteEffectInferrer {

    /// Receiver-shape test shared by the logger/metric/codec heuristics:
    /// lowercases `name` and reports whether it *contains* any of `needles`
    /// as a substring. The substring (not exact-match) policy is what lets
    /// suffixed variants — `requestLogger`, `activeRequestMeter` — qualify.
    /// `needles` must already be lowercased.
    static func isReceiver(_ name: String, matchingAnyOf needles: [String]) -> Bool {
        let lowered = name.lowercased()
        return needles.contains { lowered.contains($0) }
    }

    /// Matches `logger`, `Logger`, `log`, `Log`, `os_log`, plus suffixed
    /// variants like `requestLogger`, `rootLogger`, etc. Kept conservative —
    /// the receiver name must *literally* contain "log" (case-insensitive)
    /// as a substring. Intentionally loose on casing but tight on structure.
    static func isLoggerReceiver(_ name: String) -> Bool {
        isReceiver(name, matchingAnyOf: ["log"])
    }

    /// Matches swift-metrics primitive receivers and conventional siblings.
    /// `counter`, `Counter`, `gauge`, `meter`, `timer`, `recorder`, plus
    /// suffixed variants (`activeRequestMeter`, `requestCounter`, etc.).
    /// Round-12 follow-on — observationally absorbs metric mutations the
    /// same way the logger path absorbs log emissions.
    static func isMetricReceiver(_ name: String) -> Bool {
        isReceiver(name, matchingAnyOf: ["counter", "gauge", "meter", "timer", "recorder"])
    }

    static let metricObservationMethods: Set<String> = [
        "increment", "decrement",
        "record", "recordNanoseconds",
        "observe",
        "startTimer",
    ]

    /// Matches Foundation/SwiftNIO codec receivers. Conservative: receiver
    /// name must end with or contain `Decoder` / `Encoder` (case-insensitive
    /// via lowercasing the whole name). Silences codec instances like
    /// `decoder.decode(...)` without needing a full type resolver.
    static func isCodecReceiver(_ name: String) -> Bool {
        isReceiver(name, matchingAnyOf: ["decoder", "encoder"])
    }

    static let codecMethods: Set<String> = [
        "decode", "encode"
    ]

    static let loggerLevelMethods: Set<String> = [
        "trace", "debug", "info", "notice",
        "warning", "error", "critical", "fault",
        "log",
    ]

    static let nonIdempotentNames: Set<String> = [
        "create",
        "insert",
        "append",
        "publish",
        "enqueue",
        "post",
        "send",
        "stop",
        "destroy",
        "update",
        // Server-app verbs — added from the isowords round (slot 13).
        // `startDailyChallenge` was a real `INSERT` without `ON CONFLICT`
        // that the prior lexicon missed on the default `replayable` tier.
        "submit",
        "start",
        "complete",
        "register",
    ]

    static let idempotentNames: Set<String> = [
        "upsert",
        "setIfAbsent",
        "replace",
    ]

    /// Returns the matched prefix when `name` is a non-idempotent
    /// camelCase-composed name (e.g. `sendEmail`, `createUser`,
    /// `publishEvent`). Returns `nil` when:
    /// - `name` exactly equals a whitelist entry (handled by bare-name path)
    /// - `name` starts with a whitelist entry but the next character is
    ///   lowercase (e.g. `sending`, `sender`, `publisher`, `appending`,
    ///   `creator`) — typically participle or noun forms, not mutation verbs
    /// - `name` doesn't start with any whitelist entry
    ///
    /// The camel-case gate is the key precision mechanism. Swift methods
    /// almost always camelCase, so `prefix + Uppercase` signals a composed
    /// verb ("send-email", "create-user") while `prefix + lowercase`
    /// signals a continuation of the prefix into a different word
    /// ("send-ing", "publish-er").
    static func matchesNonIdempotentPrefix(_ name: String) -> String? {
        for prefix in nonIdempotentNames {
            guard name.hasPrefix(prefix), name.count > prefix.count else { continue }
            let nextIndex = name.index(name.startIndex, offsetBy: prefix.count)
            if name[nextIndex].isUppercase { return prefix }
        }
        return nil
    }
}
