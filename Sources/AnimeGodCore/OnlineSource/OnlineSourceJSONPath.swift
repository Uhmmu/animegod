import Foundation

/// The slice of JSONPath a source rule actually uses.
///
/// Deliberately not a JSONPath implementation. Every expression in the live
/// rule catalog was collected and there are eleven distinct ones, all of the
/// same shape — a root, dot-separated keys, and a wildcard over an array:
///
///     $          $.data          $.list[*]        $.data.records[*]
///     $[*]       $.name          $.title          $.id
///     $.sources[*]               $.episodes[*]    $.episodeLabel
///
/// Filters, slices, recursive descent and unions are not used by any rule,
/// and implementing them would mean maintaining an expression language for
/// no site that exists. A path this does not understand returns nothing,
/// which surfaces as "this rule found nothing" rather than a wrong answer.
public enum OnlineSourceJSONPath {
    /// One step of a path: a key, or "every element of this array".
    enum Step: Equatable {
        case key(String)
        case everyElement
        /// A single index, written `[2]` — not in the current catalog but
        /// free to support, since parsing already has the brackets open.
        case element(Int)
    }

    /// Splits an expression into steps, or nil when it is not a shape this
    /// understands.
    static func parse(_ expression: String) -> [Step]? {
        var path = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("$") { path.removeFirst() }
        var steps: [Step] = []
        var cursor = path.startIndex

        while cursor < path.endIndex {
            switch path[cursor] {
            case ".":
                cursor = path.index(after: cursor)
                // `..` is recursive descent, which nothing uses and which
                // must not be mistaken for a key named "".
                if cursor < path.endIndex, path[cursor] == "." { return nil }
                var name = ""
                while cursor < path.endIndex, path[cursor] != ".", path[cursor] != "[" {
                    name.append(path[cursor])
                    cursor = path.index(after: cursor)
                }
                guard !name.isEmpty else { return nil }
                if name == "*" {
                    steps.append(.everyElement)
                } else {
                    steps.append(.key(name))
                }
            case "[":
                cursor = path.index(after: cursor)
                var inner = ""
                while cursor < path.endIndex, path[cursor] != "]" {
                    inner.append(path[cursor])
                    cursor = path.index(after: cursor)
                }
                guard cursor < path.endIndex else { return nil }
                cursor = path.index(after: cursor)
                let trimmed = inner.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
                if trimmed == "*" {
                    steps.append(.everyElement)
                } else if let index = Int(trimmed) {
                    steps.append(.element(index))
                } else if !trimmed.isEmpty, !inner.contains("?"), !inner.contains(":") {
                    // A quoted key, `['name']`.
                    steps.append(.key(trimmed))
                } else {
                    return nil
                }
            default:
                return nil
            }
        }
        return steps
    }

    /// Every value an expression selects.
    public static func values(_ expression: String, in json: Any) -> [Any] {
        guard let steps = parse(expression) else { return [] }
        var current: [Any] = [json]
        for step in steps {
            var next: [Any] = []
            for value in current {
                switch step {
                case let .key(name):
                    if let object = value as? [String: Any], let found = object[name] {
                        next.append(found)
                    }
                case .everyElement:
                    if let array = value as? [Any] {
                        next.append(contentsOf: array)
                    }
                case let .element(index):
                    if let array = value as? [Any], array.indices.contains(index) {
                        next.append(array[index])
                    }
                }
            }
            current = next
            if current.isEmpty { return [] }
        }
        return current
    }

    /// The first value an expression selects.
    public static func value(_ expression: String, in json: Any) -> Any? {
        values(expression, in: json).first
    }

    /// The first value as text.
    ///
    /// A number is read as text because that is what these fields are for:
    /// a search result's `id` is a number in the response and a path segment
    /// in the URL built from it, and `9.0` must become `9` or the URL is
    /// wrong.
    public static func string(_ expression: String, in json: Any) -> String? {
        guard let value = value(expression, in: json) else { return nil }
        return text(of: value)
    }

    static func text(of value: Any) -> String? {
        if let text = value as? String { return text }
        // `JSONSerialization` hands back `NSNumber` for every number *and*
        // for every boolean, and an `NSNumber` holding `true` casts to `Int`
        // as 1 — so the boolean has to be told apart by its type id before
        // any numeric cast is tried.
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            let double = number.doubleValue
            guard double == double.rounded(), abs(double) < 1e18 else { return String(double) }
            return String(number.int64Value)
        }
        if let flag = value as? Bool { return flag ? "true" : "false" }
        if let number = value as? Int { return String(number) }
        if let number = value as? Double {
            return number == number.rounded() ? String(Int(number)) : String(number)
        }
        return nil
    }
}
