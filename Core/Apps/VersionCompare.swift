import Foundation

/// Compares app version strings the way people read them.
///
/// - Dotted parts are compared one by one with `compare(options: .numeric)`, so 1.10 > 1.9.
/// - Missing parts count as 0, so 2.0 == 2.0.0.
/// - A build in brackets or after a comma ("1.2 (345)", Homebrew's "1.2,345") breaks ties when
///   both sides have one; it never outweighs the main version. Against a longer dotted version
///   without a build ("7.2.2.88465") it is read as the next dotted part.
/// - A leading "v" is ignored; letters right after a number mark a pre-release ("2.0b4" < "2.0").
enum VersionCompare {
    struct Parsed: Equatable {
        var main: [String]
        var build: [String]?
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = parse(lhs)
        let b = parse(rhs)
        // "7.2.2 (88465)" and Homebrew's "7.2.2.88465" are the same release: when only one side
        // has a separate build and the other's dotted version is longer, compare main + build.
        if let build = a.build, b.build == nil, b.main.count > a.main.count {
            return comparePartLists(a.main + build, b.main)
        }
        if let build = b.build, a.build == nil, a.main.count > b.main.count {
            return comparePartLists(a.main, b.main + build)
        }
        let main = comparePartLists(a.main, b.main)
        if main != .orderedSame { return main }
        guard let left = a.build, let right = b.build else { return .orderedSame }
        return comparePartLists(left, right)
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        compare(candidate, installed) == .orderedDescending
    }

    static func parse(_ raw: String) -> Parsed {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var build: String?
        if let open = text.firstIndex(of: "("), let close = text[open...].firstIndex(of: ")") {
            build = String(text[text.index(after: open)..<close])
            text = String(text[..<open])
        } else if let comma = text.firstIndex(where: { $0 == "," || $0 == ":" }) {
            build = String(text[text.index(after: comma)...])
            text = String(text[..<comma])
        }
        text = text.trimmingCharacters(in: .whitespaces)
        if let first = text.first, first == "v" || first == "V", text.dropFirst().first?.isNumber == true {
            text.removeFirst()
        }
        // "1.2 build 7" or "1.2-beta 3": keep only the first word.
        if let space = text.firstIndex(of: " ") { text = String(text[..<space]) }
        return Parsed(main: parts(text), build: build.map { parts($0) }.flatMap { $0.isEmpty ? nil : $0 })
    }

    private static func parts(_ text: String) -> [String] {
        text.trimmingCharacters(in: .whitespaces).split(separator: ".").map(String.init).filter { !$0.isEmpty }
    }

    private static func comparePartLists(_ a: [String], _ b: [String]) -> ComparisonResult {
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : "0"
            let right = index < b.count ? b[index] : "0"
            let result = comparePart(left, right)
            if result != .orderedSame { return result }
        }
        return .orderedSame
    }

    /// "10" vs "9" numerically; "0b4" (pre-release) sorts before "0"; otherwise numeric text compare.
    private static func comparePart(_ a: String, _ b: String) -> ComparisonResult {
        let (aNumber, aRest) = split(a)
        let (bNumber, bRest) = split(b)
        if let aNumber, let bNumber {
            let numbers = aNumber.compare(bNumber, options: .numeric)
            if numbers != .orderedSame { return numbers }
            switch (aRest.isEmpty, bRest.isEmpty) {
            case (true, true): return .orderedSame
            case (true, false): return .orderedDescending
            case (false, true): return .orderedAscending
            case (false, false): return aRest.compare(bRest, options: [.numeric, .caseInsensitive])
            }
        }
        return a.compare(b, options: [.numeric, .caseInsensitive])
    }

    /// Leading digits and the rest ("0b4" → ("0", "b4")); nil digits when it doesn't start with one.
    private static func split(_ part: String) -> (String?, String) {
        let digits = part.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return (nil, part) }
        var rest = part.dropFirst(digits.count)
        while let first = rest.first, first == "-" || first == "_" || first == "+" { rest.removeFirst() }
        // Leading zeros don't matter numerically ("01" == "1").
        let trimmed = digits.drop { $0 == "0" }
        return (trimmed.isEmpty ? "0" : String(trimmed), String(rest))
    }
}
