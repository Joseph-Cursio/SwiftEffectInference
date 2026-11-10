// MARK: - Substring helpers

extension Substring {

    func trimmingLeadingWhitespace() -> Substring {
        var slice = self
        while let char = slice.first, char == " " || char == "\t" { slice = slice.dropFirst() }
        return slice
    }

    func firstWord() -> String {
        var out = ""
        for char in self {
            if char.isWhitespace { break }
            if char == "(" || char == ":" { break }
            out.append(char)
        }
        return out
    }

    /// Reads the longest prefix of identifier characters (letters, digits,
    /// underscore).
    func firstIdentifier() -> Substring {
        var end = startIndex
        for idx in indices {
            let char = self[idx]
            if char.isLetter || char.isNumber || char == "_" {
                end = index(after: idx)
            } else {
                break
            }
        }
        return self[startIndex..<end]
    }
}
